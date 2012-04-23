package Tversky;

use strict;

use parent 'Exporter';
our @EXPORT_OK = 'htmlsafe';

use DBIx::Simple;
use SQL::Abstract;
use CGI::Minimal;
use HTML::Entities 'encode_entities';
use File::Slurp 'slurp';

my $mturk_sandbox_submit_url = 'https://workersandbox.mturk.com/mturk/externalSubmit';
my $mturk_production_submit_url = 'https://www.mturk.com/mturk/externalSubmit';

# --------------------------------------------------
# Public subroutines
# --------------------------------------------------

sub htmlsafe
   {encode_entities $_[0], q(<>&"')}

# --------------------------------------------------
# Private subroutines
# --------------------------------------------------

sub randelm
   {$_[ int(rand() * @_) ]}

sub chomped
   {my $x = shift;
    chomp $x;
    $x;}

# --------------------------------------------------
# Public methods
# --------------------------------------------------

sub new
   {my $invocant = shift;
    my %h =
        (mturk => undef,
         here_url => undef,

         database_path => undef,
         tables => {},

         consent_path => undef,
         consent_regex => qr/\A \s* ['"]? \s* i \s+ consent \s* ['"]? \s* \z/xi,

         experiment_complete => '<p>The experiment is complete. Thanks for your help!</p>',

         task_version => undef,
         preview => sub { print '<p>(No preview available.)</p>' },
         after_consent_prep => sub {},
         footer => "</body></html>\n",
         @_);
    defined $h{tables}{$_} or die "No table supplied for '$_'"
        foreach qw(subjects timing user);
    if ($h{mturk})
       {$h{mturk} eq 'sandbox' or $h{mturk} eq 'production'
            or die "Illegal value for 'mturk': $h{mturk}";
        defined $h{tables}{'mturk'} or die "No table supplied for 'mturk'";}

    my $o = bless \%h, ref($invocant) || $invocant;

    $o->{db} = DBIx::Simple->connect("dbi:SQLite:dbname=$h{database_path}")
        or die DBIx::Simple->error;
    $o->{db}->abstract = new SQL::Abstract;
    $o->{db}->{sqlite_unicode} = 1;
    $o->{db}->{sqlite_see_if_its_a_number} = 1;
    $o->sql('pragma foreign_keys = on');

    my $ip = $ENV{REMOTE_ADDR} =~ /(\d+) \. (\d+) \. (\d+) \. (\d+)/x
      ? "$1.$2.$3.$4"
      : die 'badip';

    my %p = do 
       {my $cgi = new CGI::Minimal;
        map {$_ => $cgi->param($_)} $cgi->param};

    my %s = $o->getrow('subjects', ip => $ip);
    $o->{sn} = $s{sn}; # Which may not exist yet.

    unless (%s)
      # We have no existing record of this person.
       {if ($o->{mturk} and not exists $p{workerId})
         # The worker is previewing this HIT.
           {$o->{preview}->();
            $o->quit;}
        # In MTurk, the worker just accepted the HIT. Otherwise,
        # we're seeing this IP address for the first time. Either
        # way, make a new row in the subjects table for this
        # person.
        $o->insert('subjects',
            ip => $ip,
            first_seen_t => time);
        %s = $o->getrow('subjects', ip => $ip);
        $o->{sn} = $s{sn};
        $o->{mturk} and
            $o->insert('mturk',
                sn => $o->{sn},
                workerid => $p{workerId},
                hitid => $p{hitId},
                assignmentid => $p{assignmentId});}

    unless ($s{consented_t})
       {if ($p{consent_statement} and
            $p{consent_statement} =~ $o->{consent_regex})
          # The subject just consented. Log the time and task
          # version and set up the experiment.
           {$o->transaction(sub
               {$o->modify('subjects', {sn => $o->{sn}},
                   {consented_t => time,
                    task_version => $o->{task_version}});
                $o->{after_consent_prep}->($o);});}
        else
          # The subject hasn't consented, so show the consent form.
           {print slurp($o->{consent_path});
            print $o->form(sprintf '<div style="%s">%s<br>%s</div>',
                'text-align: center',
                '<input type="text" class="consent_statement" name="consent_statement" value="">',
                '<button type="submit" name="consent_button" value="submitted">OK</button>');
            $o->quit;}}

    $o->{params} = \%p;
    $o->{user} = {map
        {$_->{k} => $_->{v}}
        $o->getrows('user', sn => $o->{sn})};
    $o->{timing} = {map
        {$_->{k} =>
           {first_sent => $_->{first_sent},
            received => $_->{received}}}
        $o->getrows('timing', sn => $o->{sn})};
    return $o;}

sub save
   {my ($self, $key, $value) = @_;
    $self->replace('user',
        sn => $self->{sn}, k => $key, v => $value);
    $self->{user}{$key} = $value;}

sub getu
   {my ($self, $key) = @_;
    $self->{user}{$key};}

sub randomly_assign
   {my ($self, $key, @vals) = @_;
    $self->save($key, randelm @vals);}

sub okay_page
   {my ($self, $key, $content) = @_;
    $self->page(key => $key,
        content => $content,
        fields => [{name => 'next_button',
            html => '<p><button class="next_button" name="next_button" value="next" type="submit">Next</button></p>',
            proc => sub { $_ eq 'next' or undef }}]);}

sub discrete_rating_page
   {my ($self, $key, $content, $scale_points, $anchor_lo, $anchor_hi) = @_;
    $self->page(key => $key,
        content => $content,
        fields => [{name => 'discrete_scale',
            k => $key,
            html => join('',
              '<p>', htmlsafe($anchor_lo),
              (map
                 {"<button class='discrete_scale_button' name='discrete_scale' value='$_' type='submit'></button>"}
                 1 .. $scale_points),
              htmlsafe($anchor_hi),'</p>'),
            #html => '<input type="text" name="discrete_scale"/>',
            proc => sub 
               {/\A(\d+)\z/ or return undef;
                return $1 >= 1 && $1 <= $scale_points
                  ? $1
                  : undef;}}]);}

sub yesno_page
   {my ($self, $key, $content) = @_;
    $self->page(key => $key,
        content => $content,
        fields => [{name => 'yesno',
            k => $key,
            html =>
                '<p>' .
                '<button name="yesno" value="yes" type="submit">Yes</button>' .
                '<button name="yesno" value="no" type="submit">No</button>' .
                '</p>',
            proc => sub 
               {$_ eq 'yes' ? 1 : $_ eq 'no' ? 0 : undef;}}]);}

sub completion_page
   {my $self = shift;
    $self->modify('subjects',
       {sn => $self->{sn}, completed_t => undef},
       {completed_t => time});
    print $self->{experiment_complete};
    if ($self->{mturk})
      # Create a HIT-submission button.
       {my %r = $self->getrow('mturk', sn => $self->{sn});
        print sprintf '<form method="post" action="%s">%s</form>',
            htmlsafe($self->{mturk} eq 'production'
              ? $mturk_production_submit_url
              : $mturk_sandbox_submit_url),
            join '',
                 (map {sprintf '<input type="hidden" name="%s" value="%s"/>',
                           map {htmlsafe $_} @$_}
                    [assignmentId => $r{assignmentid}],
                    [hitId => $r{hitid}]),
                '<button name="submit_hit_button" value="submitted" type="submit">Submit HIT</button>';}
    $self->quit;}

# --------------------------------------------------
# Private methods
# --------------------------------------------------

my $sql_abstract = new SQL::Abstract;

sub sql
   {my $self = shift;
    $self->{db}->query(@_) or die $self->{db}->error}

sub sel
   {my $self = shift;
    $self->{db}->select($self->{tables}{$_[0]}, @_[1 .. $#_])
        or die $self->{db}->error;}
sub modify
   {my ($self, $table, $where, $update) = @_;
    $self->{db}->update($self->{tables}{$table}, $update, $where)
        or die $self->{db}->error;}
sub insert
   {my ($self, $table, %fields) = @_;
    $self->{db}->insert($self->{tables}{$table}, \%fields)
        or die $self->{db}->error;}
sub maybe_insert
# Like "insert" above, but uses SQLite's INSERT OR IGNORE.
   {my ($self, $table, %fields) = @_;
    my ($statement, @bind) = $sql_abstract->insert
       ($self->{tables}{$table}, \%fields);
    $statement =~ s/\AINSERT /INSERT OR IGNORE /i or die 'insert-or-ignore';
    $self->sql($statement, @bind);}
sub replace
# Like "insert" above, but uses SQLite's INSERT OR REPLACE.
   {my ($self, $table, %fields) = @_;
    my ($statement, @bind) = $sql_abstract->insert
       ($self->{tables}{$table}, \%fields);
    $statement =~ s/\AINSERT /INSERT OR REPLACE /i or die 'insert-or-replace';
    $self->sql($statement, @bind);}
sub getrows
   {my ($self, $table, %where) = @_;
    $self->sel($table, '*', \%where)->hashes};
sub getrow
   {my ($self, $table, %where) = @_;
    %{ ($self->sel($table, '*', \%where)->hashes)[0] || {} } };
sub count
   {my ($self, $table, %where) = @_;
    ($self->sel($table, 'count(*)', \%where)->flat)[0];}
sub transaction
   {my ($self, $f) = @_;
    $self->{db}->begin;
    eval {$f->()};
    if ($@)
       {$self->{db}->rollback;
        die;}
    else
       {$self->{db}->commit;}}

sub page
   {my $self = shift;
    my %h = (key => undef, content => undef, fields => [], @_);
    my $key = $h{key};

    # If the subject has already done this part of the task, skip it.
    $self->begin($key) or return;

    # If the subject has just sent a reply, validate it. If it
    # all looks good, record it and move on; otherwise, repeat
    # the task.
    VALIDATE: {
    if (exists $self->{params}{key} and
            $self->{params}{key} eq htmlsafe($key))
       {my %to_save;
        foreach my $f (@{$h{fields}})
           {exists $self->{params}{$f->{name}} or last VALIDATE;
            local $_ = $self->{params}{$f->{name}};
            my $v = $f->{proc}->();
            defined $v or last VALIDATE;
            exists $f->{k} and $to_save{$f->{k}} = $v;}
        $self->transaction(sub
           {$self->save($_, $to_save{$_}) foreach keys %to_save;
            $self->now_done($key);});
        # Clear $self->{params} so responses to this task aren't
        # mistaken for responses to another task.
        $self->{params} = {};
        return;}}

    # Show the task.
    print "<div class='expbody'>$h{content}</div>";
    print $self->form(
        sprintf('<input type="hidden" name="key" value="%s">',
            htmlsafe($key)),
        (map {$_->{html}} @{$h{fields}}));
    $self->quit;}

sub form
   {my $self = shift;
    sprintf '<form method="post" action="%s">%s</form>',
        htmlsafe($self->{here_url}),
        join '', @_}

sub begin
# If the part of the task referenced by $key is already done,
# return false. Otherwise, return true, setting the first_sent
# time for this key if it isn't already set.
   {my ($self, $key) = @_;
    defined $self->{timing}{$key}{received} and return 0;
    unless (defined $self->{timing}{$key}{first_sent})
       {$self->{timing}{$key}{first_sent} = time;
        $self->insert('timing',
            sn => $self->{sn},
            k => $key,
            first_sent => $self->{timing}{$key}{first_sent});}
    return 1;}

sub now_done
   {my ($self, $key) = @_;
    $self->{timing}{$key}{received} = time;
    $self->modify('timing',
        {sn => $self->{sn}, k => $key},
        {received => $self->{timing}{$key}{received}});}

sub quit
   {my $self = shift;
    print $self->{footer};
    exit;}
