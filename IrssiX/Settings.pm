package IrssiX::Settings;

use warnings;
use strict;

our $VERSION = '0.05';

use again Carp => qw(croak);
use again 'IrssiX::Util' => qw(on_settings_change run_from_caller);

sub import {
	my $pkg = shift;

	my %options;
	if ($_[0] && ref($_[0]) eq 'HASH') {
		%options = %{+shift};
	}

	for ($options{prefix}) {
		if (defined) {
			/^[A-Za-z_][A-Za-z_0-9]*\z/ or croak qq[Malformed variable prefix "$_" in ${pkg}::import()];
		} else {
			$_ = '';
		}
	}
	my $options_prefix = delete $options{prefix};
	%options and croak "Invalid options (@{[keys %options]}) in ${pkg}::import()";

	@_ % 2 == 0 or croak "Odd number of elements in ${pkg}::import()";

	my $caller = caller;
	(my $script = $caller) =~ s/^.*:://s;

	my $after_refresh = sub {};

	my %normalized;

	while (my ($name, $spec) = splice @_, 0, 2) {
		defined $name && defined $spec or croak "Use of uninitialized value in ${pkg}::import()";

		if ($name eq '*') {
			ref($spec) eq 'CODE' or croak qq[Value for "*" must be a coderef];
			$after_refresh = $spec;
			next;
		}

		$name =~ /^[a-zA-Z_][a-zA-Z_0-9]*\z/ or croak qq[Malformed settings name "$name" in ${pkg}::import()];

		exists $normalized{$name} and croak qq[Redefinition of "$name" in ${pkg}::import()];

		if (ref $spec) {
			if (ref($spec) eq 'Regexp') {
				$spec = ['qr', $spec];
			} elsif (grep $spec->[0] eq $_, qw(str str-expand qw-set qw-set-lc)) {
				@$spec > 1 or $spec = [$spec->[0], ''];
			} elsif (grep $spec->[0] eq $_, qw(int time)) {
				@$spec > 1 or $spec = [$spec->[0], 0];
			} elsif ($spec->[0] eq 'qr') {
				$spec = [
					$spec->[0],
					@$spec < 0 ? qr// :
					ref($spec->[1]) eq 'Regexp' ? $spec->[1] :
					qr/$spec->[1]/
				];
			} else {
				croak qq!Invalid settings type "$spec->[0]" in ${pkg}::import()!;
			}
		} else {
			if ($spec =~ /^[0-9]+\z/) {
				$spec = ['int', 0 + $spec];
			} else {
				$spec = ['str', $spec];
			}
		}

		$normalized{$name} = $spec;
	}

	my $refresh_code = '';

	for my $name (keys %normalized) {
		my $spec = $normalized{$name};
		my ($type, $default) = @$spec;
		my $itype = $type eq 'int' || $type eq 'time' ? $type : 'str';
		my $create_func = \&{"Irssi::settings_add_$itype"};
		
		run_from_caller sub {
			@_ = ($script, "${script}_$name", $default);
			goto &$create_func;
		};

		my $vname = $options_prefix . $name;

		if ($type eq 'qw-set') {
			$refresh_code .= qq<
				%$vname = ();
				\$${vname}{\$_} = 1 for split ' ', Irssi::settings_get_str('${script}_$name');
			>;
		} elsif ($type eq 'qw-set-lc') {
			$refresh_code .= qq<
				%$vname = ();
				\$${vname}{lc \$_} = 1 for split ' ', Irssi::settings_get_str('${script}_$name');
			>;
		} elsif ($type eq 'qr') {
			$refresh_code .= qq<
				\$$vname = do { my \$re = Irssi::settings_get_str('${script}_$name'); qr/\$re/ };
			>;
		} elsif ($type eq 'str-expand') {
			$refresh_code .= qq<
				\$$vname = do {
					my \$tmp = Irssi::settings_get_str('${script}_$name');
					\$tmp =~ s{%(.)}{
						\$1 eq 'I' ? Irssi::get_irssi_dir() :
						\$1 eq 'S' ? '$script' :
						\$1
					}ge;
					\$tmp
				};
			>;
		} else {
			$refresh_code .= qq<
				\$$vname = Irssi::settings_get_$itype('${script}_$name');
			>;
		}

		my $var = "${caller}::$vname";

		no strict 'refs';
		*{$var} = grep($_ eq $type, qw[qw-set qw-set-lc]) ? \%$var : \$$var;
	}

	my $refresh_func = eval "package $caller; sub { $refresh_code }";
	$@ and die $@;

	run_from_caller sub {
		@_ = sub { $refresh_func->(); $after_refresh->() };
		goto &on_settings_change;
	};
}

1

__END__

Copyright 2011 Lukas Mai.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

