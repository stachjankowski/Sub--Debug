package Sub::Debug;
use strict;
use warnings;

=head1 TODO
- udokumentować przypadki użycia
- posprzątać i udokumentować kod
- dodać opcje przełącznikowe np:
   -nomem lub -usemem
   -fullmem
- pozbyć się parametru ref i zastąpić za pomocą:
   - 'use Sub::Debug $result'
   - 'use Sub::Debug %result'
   - 'use Sub::Debug @result'
- dodać testy uruchamiane z poziomu serwera www
- przetestować na innych platformach: win, bsd
- przenieść do zewnętrznego repozytorium
=cut

=head1 NAME
 
Sub::Debug - Tools to inspect subroutine.
 
=head1 VERSION
 
Version 0.1

=cut

our $VERSION = '0.1';

=head1 SYNOPSIS
use Sub::Debug; # `print' is default log handler
use Sub::Debug sub { print @_ };
use Sub::Debug \&Log::Info;
use Sub::Debug 'Log::Info';

sub TestedSub : Debug(exclude=>[qw($self)]) {
sub TestedSub : Debug(include=>[qw($self)]) {
=cut

use Attribute::Handlers;
use B;
use Data::Dumper;
use List::MoreUtils qw/any none firstidx/;
use Module::Load;
use PadWalker qw/peek_sub/;
eval 'use Memory::Usage';
my $use_memory_full_report = !$@;

my $log_handler;
my $ref_handler;

sub import {
    my $class = shift;
    my $type = ref($_[0]);
    if ( $type eq 'CODE' ) {                        # use Sub::Debug sub{...}
        $log_handler = shift;
    } elsif ( $type eq 'ARRAY' ) {                  # use Sub::Debug \@return
        my $ref = shift;
        $ref_handler = sub { push @{$ref}, $_[0] };
    } elsif ( $type eq 'HASH' ) {                   # use Sub::Debug \%return
        my $ref = shift;
        $ref_handler = sub { %{ $ref } = %{ $_[0] } };
    } else {                                        # use Sub::Debug or use Sub::Debug 'Log::Info'
        my $full_sub_name = shift;
        if ( $full_sub_name && $full_sub_name =~ /::/ ) {
            $full_sub_name =~ /^(.*)::(.*?)$/;
            my ($pkg, $subname) = ($1, $2);
            eval {
                load $pkg;
                no strict 'refs';
                $log_handler = *{$full_sub_name};
            }
        }
        unless ( $log_handler ) {
            $log_handler = sub { print @_ };
        }
    }
}

sub UNIVERSAL::Debug : ATTR(CODE) {
    my ($package, $symbol, $referent, undef, $data, undef, $filename) = @_;
    $filename ||= locate_file_by_package($package);
    my $cv = B::svref_2object( $symbol );
    my $full_sub_name = $package."::".$cv->SAFENAME();
    my @in_names = _in_names($filename, $cv->NAME);
    my %params = _parse_args($data);

    no warnings 'redefine';
    *{$symbol} = sub {
        my $in_vars = _bind_in_vars(\@in_names, [@_]);
        my $direction = $params{'include'} ? 'include'             : $params{'exclude'} ? 'exclude'             : '';
        my @names     = $params{'include'} ? @{$params{'include'}} : $params{'exclude'} ? @{$params{'exclude'}} : ();
        my $sub_vars = peek_sub($referent);
        _filter_variables($direction, $sub_vars, @names);
        _filter_variables($direction, $in_vars, @names);
        my $before_vars = {
            'in'           => $in_vars
        };
        my ($before_memory_usage, $mu);
        unless ( $params{nomem} ) {
            $before_memory_usage = memory_usage();
            $before_vars->{'memory_usage'} = $before_memory_usage;
            if ( $use_memory_full_report ) {
                $mu = Memory::Usage->new();
                $mu->record('before');
            }
        }
        my $after_vars = {
            'sub'     => $sub_vars
        };
        $ref_handler->({ before => $before_vars, after => $after_vars }) if $ref_handler;

        my $uniqID = sprintf "%07p", rand;
        local $Data::Dumper::Terse = 1;
        {
            local $Data::Dumper::Sortkeys = _get_sort_sub(@in_names);
            $log_handler->("Variables before executing $full_sub_name (uniqID: $uniqID ):\n" . Dumper $before_vars);
        }
        my (@ret, $ret, $err);
        my $what_you_want = wantarray ? 'wantarray' : defined wantarray ? 'scalar' : 'nothing';
        eval {
            if ($what_you_want eq 'wantarray') {
                @ret = &{$referent};
            } elsif ($what_you_want eq 'scalar') {
                $ret = &{$referent};
            } else {
                &$referent;
            }
            1;
        } or do {
            $err = $@
        };

        if ($what_you_want eq 'wantarray') {
            $after_vars->{'return'} = \@ret;
        } elsif ($what_you_want eq 'scalar') {
            $after_vars->{'return'} = \$ret;
        }
        $after_vars->{'error'} = "$err" if $err;
        unless ( $params{nomem} ) {
            $after_vars->{'memory_usage'} = 'memory_usage_to_replace';
            $after_vars->{'memory_leak'} = 'memory_leak_to_replace';
            if ( $use_memory_full_report ) {
                $mu->record('after');
                $after_vars->{'memory_report'} = "\n".$mu->report();
            }
        }
        my $dump = Dumper $after_vars;
        ## free memory
        unless ( $ref_handler ) {
            undef $after_vars;
            undef $before_vars;
        }

        unless ( $params{nomem} ) {
            my $after_memory_usage = memory_usage();
            my $memory_leak = $after_memory_usage - $before_memory_usage;
            $dump =~ s/memory_usage_to_replace/$after_memory_usage/;
            $dump =~ s/memory_leak_to_replace/$memory_leak/;
        }

        $log_handler->("Variables after executing $full_sub_name (uniqID: $uniqID ):\n$dump");

        die($err) if $err;  # re raise error

        return
            $what_you_want eq 'wantarray' ? @ret
          : $what_you_want eq 'scalar'    ? $ret
          : ();
    }
}

sub _get_sort_sub {
    my @in_names = @_;
    my %idxs;
    my $idx = sub {
        return $idxs{$_[0]} if $idxs{$_[0]};
        $idxs{$_[0]} = firstidx { $_ eq $_[0] } @in_names;
        return $idxs{$_[0]};
    };
    return sub {
        [
            sort {
                $idx->($a) > -1 && $idx->($b) > -1 ?
                    $idx->($a) <=> $idx->($b)
                    : lc substr($a,1) cmp lc substr($b,1)
            } keys %{$_[0]}
        ]
    }
}

sub _in_names {
    my ($file, $subname) = @_;
    return @{ _parse_line(_get_assignment_line($file, $subname)) };
}

sub _bind_in_vars {
    my ($in_names, $in_values) = @_;
    my $in_vars;
    foreach ( @$in_names ) {
        my $first_char = substr($_,0,1);
        if ( $first_char eq '$' ) {
            $in_vars->{$_} = \shift(@$in_values);
        } elsif ( $first_char eq '@' ) {
            $in_vars->{$_} = [@$in_values];
            @$in_values = ();
            last;
        } elsif ( $first_char eq '%' ) {
            $in_vars->{$_} = {@$in_values};
            @$in_values = ();
            last;
        }
    }
    if ( @$in_values ) {
        $in_vars->{'@_'} = [@$in_values];
    }
    return $in_vars;
}

sub _get_assignment_line {
    my ( $file, $subname ) = @_;

    die("Filename $file does not exists") unless -e $file;
    die("No subname specified") unless $subname;

    my ($buffer, $match);
    open my $FH, '<', $file or die("Problem with opening $file");
    while ( my $line = <$FH> ) {
        chomp $line;
        if ( $line =~ / sub \s* $subname \b /x || $match ) {
            $buffer .= $line;
            last if $match;
            $match = 1;
        } else {
            $match = 0;
        }
    }
    close $FH;
    return ($buffer =~ /( my .* ; )/x) ? $1 : '';
}

sub _parse_line {
    return shift =~ / my \s* \(? (.*?) [\)|=] /x ?
      [ map { /^ \s* (.*?) \s* $/x && $1 } split /,/, $1 ]
      : []
}

sub _filter_variables {
    my ($direction, $vars, @names) = @_;

    if ( $direction eq 'include' ) {
        foreach my $key (keys %{$vars}) {
            if ( none { $_ eq $key } @names ) {
                delete $vars->{$key};
            }
        }
    } elsif ( $direction eq 'exclude' ) {
        foreach my $key (keys %{$vars}) {
            if ( any { $_ eq $key } @names ) {
                delete $vars->{$key};
            }
        }
    }
}

sub _parse_args {
    my $data = shift;
    my @args = @{ $data || [] };
    my @params;
    while ( my $arg = shift(@args) ) {
        push @params, $arg =~ /^\-/ ? (substr($arg,1) => 1) : $arg;
    }
    return @params;
}

sub locate_file_by_package {
   my $file = shift;
   $file =~ s@ \:\: @/@gx;
   $file = "$file.pm";
   return $INC{$file} || (-e $file ? $file : "");
}

sub memory_usage {
   open(my $statm, "<", "/proc/$$/statm");
   my @stat = split /\s+/, <$statm>;
   close $statm;
   return $stat[1] * .004;
}

=head1 LICENSE
"THE BEER-WARE LICENSE" (Revision 42):
<stach.jankowski@gmail.com> wrote this file. As long as you retain this notice you
can do whatever you want with this stuff. If we meet some day, and you think
this stuff is worth it, you can buy me a beer in return Stach Jankowski.
=cut

1;
