#!/usr/bin/perl

use feature 'say';
use warnings;
use strict;

use DBIx::Simple;
use IPC::System::Simple 'systemx';
use Time::HiRes ();

@ARGV == 1 or die;
my $sleep_time = $ARGV[0];

my $db_path = '/tmp/Tversky-locking-test.sqlite';

systemx 'rm', '-f', $db_path;

sub db_connect ()
   {my $dbh = DBIx::Simple->connect("dbi:SQLite:dbname=$db_path", '', '',
       {RaiseError => 1,
        sqlite_unicode => 1,
        sqlite_see_if_its_a_number => 1});
    $dbh->query('pragma foreign_keys = on');
    $dbh}

BLOCK:
   {my $db = db_connect;
    $db->query('create table Foo (n integer primary key, v text);');
    $db->insert('Foo', {n => 1, v => 'row 1'});
    $db->disconnect;}

my $kidpid = fork;
if ($kidpid)
  # Parent
   {Time::HiRes::sleep(.5);
    my $db = db_connect;
    say 'Parent: Starting transaction';
    $db->begin;
    $db->insert('Foo', {n => 2, v => 'row 2'});
    say 'Parent: Inserted 2';
    say 'Parent: Sending alarm to child at ', Time::HiRes::time;
    kill 'USR1', $kidpid;
    say 'Parent: Sleeping';
    my $t1 = Time::HiRes::time;
    Time::HiRes::sleep($sleep_time);
    say 'Parent: Slept ', Time::HiRes::time() - $t1;
    $db->insert('Foo', {n => 3, v => 'row 3'});
    say 'Parent: Inserted 3';
    $db->commit;
    $db->disconnect;
    waitpid $kidpid, 0;}
else
  # Child
   {local $SIG{USR1} = sub { say 'Child: Caught SIGUSR1'; };
    sleep;
    say 'Child: Woke at ', Time::HiRes::time;
    my $db = db_connect;
    say 'Child: Trying to insert';
    my $t1 = Time::HiRes::time;
    $db->insert('Foo', {n => 4, v => 'row 4'});
    say 'Child: Inserted 4';
    say 'Child: Waited ', Time::HiRes::time() - $t1;
    $db->disconnect;
    exit;}
