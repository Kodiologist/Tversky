#!/usr/bin/env python

import os
import sqlite3
import argparse
import imp; mturk = imp.load_source('mturk', os.environ['BOTO_MTURK_CLI'])

# --------------------------------------------------

def die(x): raise ValueError(x)

# --------------------------------------------------

par = argparse.ArgumentParser()
mturk.add_argparse_arguments(par)
par.add_argument('database',
    help = 'path to a Tversky SQLite database')
par.add_argument('hit',
    help = 'nickname or ID of a HIT')
args = par.parse_args()

mturk.init_by_args(args)

# --------------------------------------------------

hit = mturk.get_hitid(args.hit)

submitted = {x['AssignmentId']: x for x in mturk.list_assignments(hit)}

db = sqlite3.connect(args.database)
db.row_factory = sqlite3.Row
c = db.cursor()

# --------------------------------------------------

# Remove already reconciled assignments from 'submitted'.
for a in submitted.keys():
    c.execute('select count(*) from MTurk where reconciled = 1 and assignmentid = ?', [a])
    if c.fetchone()[0]:
        del submitted[a]

# For each submitted, unreconciled assignment in the database,
# check the information in the database against the information
# from MTurk.

for dbrow in list(c.execute('select * from Subjects natural join MTurk where hitid = ? and reconciled = 0 and completion_key is not null', [hit])):
    dbrow = dict(dbrow)
    a = submitted.get(dbrow['assignmentid'])
    if not a:
        die('No assignment submitted: {}'.format(dbrow))
    if a['WorkerId'] != dbrow['workerid']:
        die("Submitted worker ID ({}) doesn't match: {}".format(a['WorkerId'], dbrow))
    if int(a['answers']['tversky_completion_key']) != dbrow['completion_key']:
        die("Submitted completion key ({}) doesn't match: {}".format(a['answers']['tversky_completion_key'], dbrow))
    c.execute('select count(*) from MTurk where workerid = ?', [dbrow['workerid']])
    n, = c.fetchone()
    if n != 1:
        print 'Multiple MTurk rows ({}) for {}'.format(n, dbrow['workerid'])
    del submitted[dbrow['assignmentid']]
    print 'Looks good: subject', dbrow['sn']
    # Mark the checked assignment as reconciled.
    c.execute('update MTurk set reconciled = 1 where sn = ?', [dbrow['sn']])

if submitted:
    die('Irreconcilable assignments: {}'.format(submitted))

# --------------------------------------------------

print 'Zero out all cookie expiration times?',
if raw_input().strip().lower() in ('y', 'yes'):
    c.execute('update Subjects set cookie_expires_t = 0')
    print 'Zeroed out.'
else:
    print "All right, I won't."

db.commit()
