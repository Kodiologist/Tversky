#!/usr/bin/perl

use warnings;
use strict;

use Test::More;
use Test::Deep;

use Tversky;

sub is_approx
   {cmp_deeply($_[0], num($_[1], 1e-8), $_[2])}

# ------------------------------------------------------------

# I computed the desired answers with GNU Units.

sub len
   {Tversky::measurement_entry_proc($_[0], \&Tversky::length_reader)}

is len('1 m'), 1;
is len('5 m'), 5;
is_approx len('3.3m'), 3.3;
is_approx len('166 centimeter'), 1.66;
is_approx len('166 centimetres'), 1.66;
is_approx len('1 foot'), .3048;
is_approx len('1 ft.'), .3048;
is_approx len('1 inch'), .0254;
is_approx len('5 ft, 3 inches'), 1.6002;
is_approx len('5 ft. 3 in.'), 1.6002;
is_approx len('5 feet and 6 in + 1 cm'), 1.6864;

is len('3feet.3inches'), undef, 'reject ambiguous input';

sub mass
   {Tversky::measurement_entry_proc($_[0], \&Tversky::mass_reader)}

is mass('1 kg'), 1;
is mass('5 kg'), 5;
is_approx mass('3.3kg'), 3.3;
is_approx mass('43 grams'), .043;
is_approx mass('43 grammes'), .043;
is_approx mass('1 pound'), 0.45359237;
is_approx mass('1 oz'), 0.028349523125;
is_approx mass('120 pounds, 2 oz'), 54.48778344625;
is_approx mass('182 pounds and 4 oz + 1 kg'), 83.6672094325;

# ------------------------------------------------------------

done_testing;
