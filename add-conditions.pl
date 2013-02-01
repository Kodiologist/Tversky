#!/usr/bin/perl

use warnings;
use strict;
use DBIx::Simple;
use URI::Escape 'uri_escape_utf8';
use Tversky qw(shuffle :table_names);

@ARGV > 2 or die "Usage: $0 DATABASE KEY [VALUE=QUANTITY]+";
my ($database_path, $key) = splice @ARGV, 0, 2;
my %add = map {split '='} @ARGV;

# ----------------------------------------------------------

my $db = DBIx::Simple->connect("dbi:SQLite:dbname=$database_path")
    or die DBIx::Simple->error;
$db->{sqlite_unicode} = 1;
$db->query('pragma foreign_keys = on')
    or die $db->error;

$db->begin;
$db->insert(CONDITIONS, {k => $key, v => $_})
        or die $db->error
    foreach shuffle map {($_) x $add{$_}} keys %add;
$db->commit;
