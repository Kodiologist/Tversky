#!/usr/bin/perl

use warnings;
use strict;
use DBIx::Simple;
use URI::Escape 'uri_escape_utf8';
use Tversky qw(shuffle :table_names);

@ARGV > 3 or die "Usage: $0 DATABASE KEY NUMBER-OF-BLOCKS [VALUE]+";
my ($database_path, $key, $blocks, @values) = @ARGV;

# ----------------------------------------------------------

my $db = DBIx::Simple->connect("dbi:SQLite:dbname=$database_path")
    or die DBIx::Simple->error;
$db->{sqlite_unicode} = 1;
$db->query('pragma foreign_keys = on')
    or die $db->error;

$db->begin;
foreach (1 .. $blocks)
   {foreach (shuffle @values)
       {$db->insert(CONDITIONS, {k => $key, v => $_})
            or die $db->error;}}
$db->commit;
printf "Added %d conditions.\n",
    $blocks * @values;
