package Tversky;

use strict;

use parent 'Exporter';
our @EXPORT_OK = qw(htmlsafe randelm shuffle);

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

sub randelm
   {$_[ int(rand() * @_) ]}

sub shuffle
   {my @a = @_;
    foreach my $n (1 .. $#a)
       {my $k = int rand $n + 1;
        $k == $n or @a[$k, $n] = @a[$n, $k];}
    return @a;}

# --------------------------------------------------
# Private subroutines
# --------------------------------------------------

sub in
   {my $item = shift;
    $item eq $_ and return $_ foreach @_;
    undef;}

sub map2 (&@)
   {my $f = shift;
    map
        {$f->(@_[2*$_, 2*$_ + 1])}
        0 .. (int(@_/2) - 1);}

# --------------------------------------------------
# Public methods
# --------------------------------------------------

sub new
   {my $invocant = shift;
    my %h =
        (mturk => undef,
         assume_consent => 0, # Turn it on for testing.
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
    $s{double_dip} and $o->double_dipped;
    $s{completed_t} and $o->completion_page;
    $o->{sn} = $s{sn}; # Which may not exist yet.

    unless (%s)
      # We have no existing record for this IP address.
       {if ($o->{mturk} and not exists $p{workerId})
         # The worker is previewing this HIT.
           {$o->{preview}->($o);
            $o->quit;}
        if ($o->{mturk})
          # The worker just accepted the HIT. Try to keep the
          # same worker from doing this task twice.
           {my %mturk = $o->getrow('mturk', workerid => $p{workerId});
            if (defined $mturk{sn})
               {$o->insert('subjects',
                    ip => $ip,
                    double_dip => 1,
                    first_seen_t => time);
                $o->double_dipped;}}
        # We seem to have a new subject. (If we're not using
        # MTurk, we're seeing this IP address for the first
        # time.) Make a new row in the subjects table for this
        # person.
        $o->transaction(sub
           {$o->insert('subjects',
                ip => $ip,
                double_dip => 0,
                first_seen_t => time);
            %s = $o->getrow('subjects', ip => $ip);
            $o->{sn} = $s{sn};
            $o->{mturk} and
                $o->insert('mturk',
                    sn => $o->{sn},
                    workerid => $p{workerId},
                    hitid => $p{hitId},
                    assignmentid => $p{assignmentId})});}

    unless ($s{consented_t})
       {if ($h{assume_consent} or
            $p{consent_statement} and
            $p{consent_statement} =~ $o->{consent_regex})
          # The subject just consented. Log the time and task
          # version and set up the experiment.
           {$o->transaction(sub
               {$o->modify('subjects', {sn => $o->{sn}},
                   {consented_t => $h{assume_consent}
                      ? 'assumed'
                      : time,
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

sub assign_permutation
   {my ($self, $key, $separator, @vals) = @_;
    $self->save($key, join $separator, shuffle @vals);}

sub okay_page
   {my ($self, $key, $content) = @_;
    $self->page(key => $key,
        content => $content,
        fields => [{name => 'next_button',
            html => '<p><button class="next_button" name="next_button" value="next" type="submit">Next</button></p>',
            proc => sub { $_ eq 'next' or undef }}]);}

sub text_entry_page
   {my ($self, $key, $content) = splice @_, 0, 3;
    my %options =
       (multiline => 0, max_chars => 256, accept_blank => 0,
        @_);
    $self->page(key => $key,
        content => $content,
        fields =>
          [{name => 'text_entry',
                k => $key,
                html => sprintf('<p>%s</p>', $options{multiline}
                  ? '<textarea class="text_entry" name="text_entry"></textarea>'
                  : '<input type="text" name="text_entry">'),
                proc => sub
                   {$options{accept_blank} or /\S/ or return undef;
                    substr $_, 0, $options{max_chars};}},
           {name => 'text_entry_submit_button',
                html => '<p><button class="next_button" name="text_entry_submit_button" value="submit" type="submit">OK</button></p>',
                proc => sub { $_ eq 'submit' or undef }}]);}

sub discrete_rating_page
   {my ($self, $key, $content) = splice @_, 0, 3;
    my %options =
       (scale_points => 7, anchors => undef, @_);

    my ($anchor_lo, $anchor_mid, $anchor_hi);
    if (defined $options{anchors})
       {if (@{$options{anchors}} == 2)
           {($anchor_lo, $anchor_hi) = @{$options{anchors}};}
        elsif (@{$options{anchors}} == 3)
           {$options{scale_points} % 2 == 0
                and die "middle anchor supplied but scale_points ($options{scale_points}) is even";
            ($anchor_lo, $anchor_mid, $anchor_hi) = @{$options{anchors}};}
        else
           {die "anchors must have 2 or 3 elements";}}

    $self->page(key => $key,
        content => $content,
        fields => [{name => 'discrete_scale',
            k => $key,
            html => sprintf('<div class="multiple_choice_box">%s</div>', join "\n",
                map
                   {sprintf '<div class="row">%s%s</div>',
                        "<button class='discrete_scale_button' name='discrete_scale' value='$_' type='submit'></button>",
                        sprintf '<div class="body">%s</div>',
                            $_ == 1 && defined $anchor_lo
                          ? htmlsafe($anchor_lo)
                          : $_ == $options{scale_points} && defined $anchor_hi
                          ? htmlsafe($anchor_hi)
                          : $_ == (1 + $options{scale_points})/2 && defined $anchor_mid
                          ? htmlsafe($anchor_mid)
                          : ''}
                reverse 1 .. $options{scale_points}),
            proc => sub 
               {/\A(\d+)\z/ or return undef;
                return $1 >= 1 && $1 <= $options{scale_points}
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
                '<button name="yesno" value="Yes" type="submit">Yes</button>' .
                '<button name="yesno" value="No" type="submit">No</button>' .
                '</p>',
            proc => sub 
               {$_ eq 'Yes' || $_ eq 'No' ? $_ : undef;}}]);}

sub multiple_choice_page
   {my ($self, $key, $content, @choices) = @_;
    $self->page(key => $key,
        content => $content,
        fields => [{name => 'multiple_choice',
            k => $key,
            html => sprintf('<div class="multiple_choice_box">%s</div>', join "\n",
                map2
                   {my ($label, $body) = @_;
                    sprintf '<div class="row">%s%s</div>',
                        sprintf('<div class="button"><button name="multiple_choice" value="%s" type="submit">%s</button></div>',
                            htmlsafe($label), htmlsafe($label)),
                        "<div class='body'>$body</div>"}
                @choices),
            proc => sub
               {in $_, map2 {$_[0]} @choices}}]);}

sub buttons_page
   {my ($self, $key, $content, @buttons) = @_;
    $self->multiple_choice_page($key, $content, map {$_, ''} @buttons);}

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

sub double_dipped
   {my $self = shift;
    print "<p>It looks like you participated in another study that makes you ineligible for this one (perhaps the same study as a different HIT). Please return this HIT.</p>";
    $self->quit;}

sub page
   {my $self = shift;
    my %h = (key => undef, content => undef, fields => [], @_);
    my $key = $h{key};

    if (defined $key)
    # An undefined $key means that this form is just for show
    # (particularly, MTurk previews) and doesn't need to interact
    # with the database.
       {# If the subject has already done this part of the task, skip it.
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
            return;}}}

    # Show the task.
    print "<div class='expbody'>$h{content}</div>";
    print $self->form(
        (defined $key
           ? sprintf('<div><input type="hidden" name="key" value="%s"></div>',
                htmlsafe($key))
           : ()),
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
