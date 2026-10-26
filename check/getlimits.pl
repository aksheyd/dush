#!/usr/bin/env perl
use strict;
use warnings;
use Errno ();
use POSIX ();

printf "INT_MAX=%d\nINT_MIN=%d\nUINT_MAX=%u\n", POSIX::INT_MAX, POSIX::INT_MIN, POSIX::UINT_MAX;
printf "LONG_MAX=%s\nLONG_MIN=%s\nULONG_MAX=%s\n", POSIX::LONG_MAX, POSIX::LONG_MIN, POSIX::ULONG_MAX;
printf "SIZE_MAX=%s\nSSIZE_MAX=%s\n", POSIX::ULONG_MAX, POSIX::LONG_MAX;
printf "INTMAX_MAX=%s\nUINTMAX_MAX=%s\n", POSIX::LONG_MAX, POSIX::ULONG_MAX;
for my $name (sort keys %!) {
  my $code = eval "Errno::$name()";
  next unless defined $code;
  local $! = $code;
  (my $text = "$!") =~ s/'/'\\''/g;
  print "$name='$text'\n";
}
