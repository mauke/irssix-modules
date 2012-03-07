package IrssiX::Util;

use warnings;
use strict;

our $_have_changepackage;

BEGIN {
	$_have_changepackage = 
		eval { require again; 1 } ?
			eval { again::require_again('Devel::ChangePackage'); 1 }
		:
			eval { require Devel::ChangePackage; 1 }
	;
}

our $VERSION = '0.04';

use Exporter qw(import);
our @EXPORT_OK = qw(
	esc
	puts
	case_fold_for
	later
	timer_add_once
	timer_add
	on_settings_change
	find_caller
	run_from_package
	run_from_caller
);

sub esc {
	my $s = join '', @_;
	$s =~ s/%/%%/g;
	$s
}

sub puts {
	@_ = (esc($_[0]), @_[1 .. $#_]);
	goto &Irssi::print;
}

my %case_fold = (
	'ascii'          => sub { my ($s) = @_; $s =~ tr/A-Z/a-z/; $s },
	'rfc1459'        => sub { my ($s) = @_; $s =~ tr/A-Z[\\]^/a-z{|}~/; $s },
	'strict-rfc1459' => sub { my ($s) = @_; $s =~ tr/A-Z[\\]/a-z{|}/; $s },
);

{
	my $last_server = 0;
	my $last_fold = $case_fold{rfc1459};

	sub case_fold_for {
		my ($server) = @_;
		my $_i = $server->{_irssi};
		return $last_fold if $last_server == $_i;
		$last_server = $_i;
		my $type = $server->isupport('CASEMAPPING') || '';
		$last_fold = $case_fold{$type} || $case_fold{rfc1459}
	}
}

sub timer_add_once {
	my ($delay, $fun) = @_;
	$delay < 10 and $delay = 10;
	@_ = ($delay, $fun, undef);
	goto &Irssi::timeout_add_once;
}

sub later (&) {
	my ($fun) = @_;
	@_ = (0, $fun);
	goto &timer_add_once;
}

sub timer_add {
	my ($delay, $fun) = @_;
	$delay < 10 and $delay = 10;
	@_ = ($delay, $fun, undef);
	goto &Irssi::timeout_add;
}

sub on_settings_change (&) {
	my ($fun) = @_;
	$fun->();
	@_ = ('setup changed', $fun);
	goto &Irssi::signal_add;
}

sub find_caller {
	my ($level) = @_;
	$level ||= 0;
	my $base = caller $level;
	#for (my $i = 0; my ($pkg, $file, $line) = caller $i; ++$i) {
	#	Irssi::print +($i == $level ? "($i)" : $i) . " $pkg in $file at $line";
	#}
	for (my $i = $level + 1; ; ++$i) {
		my $pkg = caller $i;
		$pkg or return $base;
		$pkg eq $base or return $pkg;
	}
}

sub run_from_package {
	my ($pkg, $fun, @args) = @_;
	if ($_have_changepackage) {
		my $code = 'BEGIN { Devel::ChangePackage::change_package($pkg); } $fun->(@args)';
		my $r = eval $code;
		$@ and die $@;
		return $r;
	}
	if ($pkg =~ /^[^\W\d]\w*(?:::\w+)*\z/) {
		my $code = "package $pkg; \$fun->(\@args)";
		#Irssi::print $code;
		my $r = eval $code;
		$@ and die $@;
		return $r;
	}
	local *CORE::GLOBAL::caller = sub (;$) {
		my ($n) = @_;
		$n ||= 0;
		#Irssi::print "> $n <";
		my @r = CORE::caller $n + 1;
		if ($r[0] eq 'IrssiX::Util::InternalError::_caller') {
			$r[0] = $pkg;
		}
		!wantarray ? $r[0] :
		@_ ? @r :
		@r[0 .. 2]
	};
	package IrssiX::Util::InternalError::_caller;
	$fun->(@args)
}

sub run_from_caller {
	run_from_package find_caller(1), @_
}

1

__END__

=head1 NAME

IrssiX::Util - various irssi utility functions

=head1 SYNOPSIS

  use IrssiX::Util qw(
    esc
    puts
    case_fold_for
    later
    timer_add_once
    timer_add
    on_settings_change
    find_caller
    run_from_package
    run_from_caller
  );

=head1 DESCRIPTION

A collection of various utility functions that may be useful for writing irssi
scripts. Nothing is exported by default.

=over

=item esc STRINGS

Concatenates all arguments into a single string and replaces every C<%> by C<%%>.

=item puts STRING

=item puts STRING, LEVEL

Equivalent to C<Irssi::print esc(STRING)> (or C<Irssi::print esc(STRING), LEVEL>).

=item case_fold_for SERVER

Returns an appropriate case folding function based on
C<< SERVER->isupport('CASEMAPPING') >>. C<< case_fold_for($server)->($nick) >>
will return a lowercased version of C<$nick>. This can be used to perform
case-insensitive string comparisons that automatically account for whether the
server considers e.g. C<^> and C<~> to be the same character.

=item later BLOCK

Arranges for BLOCK to be executed "later"; i.e. as soon as the current signal
is done processing.

=item timer_add_once DELAY, CODE

A wrapper around C<Irssi::timeout_add_once> that does two things: It makes sure
DELAY is at least 10 (otherwise irssi will fail for no good reason) and removes
the mandatory but useless data argument.

=item timer_add DELAY, CODE

A wrapper around C<Irssi::timeout_add> that does two things: It makes sure
DELAY is at least 10 (otherwise irssi will fail for no good reason) and removes
the mandatory but useless data argument.

=item on_settings_change BLOCK

Executes BLOCK immediately and every time the user changes a setting. Useful
for refreshing settings cached in script variables.

=item find_caller

=item find_caller LEVEL

Returns the package name from which the current function was called, skipping
over intermediate calls from the same package. Thus:

  {
    package A;
    sub f { find_caller }
    sub g { f }
  }
  {
    package B;
    sub h { A::g }
  }

Now C<B::h> will return C<B> because C<A::f> will skip over the immediate
caller C<A::g> since it comes from the same package as C<A::f>.

If you pass a LEVEL, C<find_caller> will skip over that many call frames first.
If C<A::f> had used C<find_caller 2> in the example above, it would have
skipped C<A::f> and C<A::g>, returning C<B::h>'s caller as if C<B::h> had
invoked C<find_caller> directly.

=item run_from_package PACKAGE, CODE, ARGS

Executes C<< CODE->(ARGS) >> in a way that makes L<perlfunc/caller> return
PACKAGE. This can be necessary because some of the functions provided by irssi
treat their calling package as an additional parameter (kind of). This function
lets you pass any string as PACKAGE, but it is recommended to install
L<Devel::ChangePackage> if you want to pass a PACKAGE that's not a
syntactically valid package name in Perl.

=item run_from_caller CODE, ARGS

Equivalent to C<run_from_package find_caller, CODE, ARGS>.

=back

=head1 SEE ALSO

L<irssi(1)>, L<Devel::ChangePackage>.

=head1 COPYRIGHT & LICENSE

Copyright 2011, 2012 Lukas Mai.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

=cut
