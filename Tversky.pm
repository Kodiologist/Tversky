package Tversky;

use strict;

use parent 'Exporter';
our @EXPORT_OK = qw(cat htmlsafe randelm shuffle);

use DBIx::Simple;
use SQL::Abstract;
use CGI::Minimal;
use CGI::Cookie;
use HTML::Entities 'encode_entities';
use File::Slurp 'slurp';

my $rand_base64_str_bytes = 6;
  # 6 bytes encode to 8 characters of Base64.

# --------------------------------------------------
# Public subroutines
# --------------------------------------------------

sub cat
   {join '', @_}

sub htmlsafe ($)
   {encode_entities $_[0], q(<>&"')}

my $urandom_fh;
sub rand_base64_str ()
   {defined $urandom_fh
        or open $urandom_fh, '<:raw', '/dev/urandom';
    my $buffer;
    read $urandom_fh, $buffer, $rand_base64_str_bytes;
    require MIME::Base64;
    MIME::Base64::encode_base64($buffer, '');}

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

sub hidden_inputs
   {cat map2
        sub {sprintf '<input type="hidden" name="%s" value="%s"/>', @_},
        map {htmlsafe $_}
        @_}

sub image_button_page_proc
   {/\A(\d+)\z/ or return undef;
    my $n = $1;
    $n =~ s/\A0+//;
    $n eq '' ? 0 : $n}

# --------------------------------------------------
# Public methods
# --------------------------------------------------

sub new
   {my $invocant = shift;
    my %h =
        (mturk => 0,
         assume_consent => 0, # Turn it on for testing.
         here_url => undef,
         cookie_lifespan => 12*60*60, # 12 hours
         cookie_name_suffix => undef,

         database_path => undef,
         tables => {},

         consent_path => undef,
         consent_regex => qr/\A \s* ['"]? \s* i \s+ consent \s* ['"]? \s* \z/xi,

         mturk_prompt_new_window => 0,

         experiment_complete => '<p>The experiment is complete. Thanks for your help!</p>',

         task_version => undef,
         preview => sub { print '<p>(No preview available.)</p>' },
         after_consent_prep => sub {},

         head => '<title>Study</title>',
         footer => "</body></html>\n",
         @_);
    bless \%h, ref($invocant) || $invocant;}

sub run
   {my ($self, $f) = @_;
    local $@;
    eval
       {$self->init;
        $f->();
        $self->completion_page;};
    $self->ensure_header;
    defined $@ or $@ = 'Exited "run" with undefined $@';
    $@ eq '' and $@ = 'Exited "run" with $@ set to the null string';
    warn $@;
    printf '<p>Error:</p><pre>%s</pre><p>Please report this.</p>',
        htmlsafe $@;
    $self->quit;}

sub init
   {my $o = shift;

    defined $o->{tables}{$_} or die "No table supplied for '$_'"
        foreach qw(subjects timing user);
    !$o->{mturk} or defined $o->{tables}{'mturk'}
        or die "No table supplied for 'mturk'";

    $o->{db} = DBIx::Simple->connect("dbi:SQLite:dbname=$o->{database_path}")
        or die DBIx::Simple->error;
    $o->{db}->abstract = new SQL::Abstract;
    $o->{db}->{sqlite_unicode} = 1;
    $o->{db}->{sqlite_see_if_its_a_number} = 1;
    $o->sql('pragma foreign_keys = on');

    if ($ENV{REQUEST_METHOD} eq 'POST')
       {defined $ENV{HTTP_REFERER}
            or die 'Possible XSRF attempt: POST with no referer';
        $ENV{HTTP_REFERER} =~ m!\A\Q$o->{here_url}\E(?:\z|\?|/)!
            or die "Possible XSRF attempt: POST with referer $ENV{HTTP_REFERER} (needed: $o->{here_url})";}

    my %p = do 
       {my $cgi = new CGI::Minimal;
        map {$_ => $cgi->param($_)} $cgi->param};

    my $cookie;
       {my %h = CGI::Cookie->fetch;
        %h and $cookie = $h{'Tversky_ID_' . $o->{cookie_name_suffix}};}
    my %s;
    if (defined $cookie)
       {%s = $o->getrow('subjects', cookie_id => $cookie->value);
        $o->{sn} = $s{sn};}
    unless (defined $cookie
            and %s and time <= $s{cookie_expires_t}
            and !($o->{mturk}
                and exists $p{workerId}
                and $p{workerId} ne $o->getitem('mturk', 'workerid', sn => $s{sn})))

       {if ($o->{mturk} and !exists $p{workerId} || !exists $p{assignmentId} || !exists $p{hitId} || !exists $p{turkSubmitTo})
          # The worker is previewing this HIT. Or at any rate,
          # they haven't shown us a good cookie but nor have they
          # provided all four of the MTurk parameters, so we
          # might as well just show a preview.
           {$o->ensure_header;
            $o->{preview}->($o);
            $o->quit;}

        elsif ($o->{mturk} and $o->count('mturk',
                workerid => $p{workerId},
                -bool => 'reconciled'))
          # The worker that this user is claiming to be has
          # already done this task (or has been included in the
          # MTurk table to keep them out of it).
           {$o->ensure_header;
            $o->double_dipped_page;}

        elsif ($o->{assume_consent}
                or $ENV{REQUEST_METHOD} eq 'POST'
                   and $p{consent_statement}
                   and $p{consent_statement} =~ $o->{consent_regex})
          # The subject just consented. Give them a cookie
          # and set up the experiment.
           {my $cid;
            do {$cid = rand_base64_str}
                while $o->count('subjects', cookie_id => $cid);
            my $cookie_expires_t = time + $o->{cookie_lifespan};
            $cookie = new CGI::Cookie
               (-name => 'Tversky_ID_' . $o->{cookie_name_suffix},
                -value => $cid,
                -expires => "+$o->{cookie_lifespan}s",
                  # May differ slightly from $cookie_expires_t,
                  # yeah, yeah, who cares.
                -secure => 1,
                -httponly => 1);
            $o->transaction(sub
               {$o->insert('subjects',
                    cookie_id => $cid,
                    cookie_expires_t => $cookie_expires_t,
                    ip => $ENV{REMOTE_ADDR},
                    consented_t => $o->{assume_consent}
                      ? 'assumed'
                      : time ,
                    task_version => $o->{task_version});
                %s = $o->getrow('subjects', cookie_id => $cid);
                $o->{sn} = $s{sn};
                $o->{mturk} and $o->insert('mturk',
                    sn => $s{sn},
                    workerid => $p{workerId},
                    hitid => $p{hitId},
                    assignmentid => $p{assignmentId},
                    submit_to => $p{turkSubmitTo},
                    reconciled => 0);
                $o->{after_consent_prep}->($o);});
            $o->{set_cookie} = $cookie->as_string;
            $o->ensure_header;
            if ($o->{mturk} and $o->{mturk_prompt_new_window})
               {$o->prompt_new_window_page;}}

        else
          # The subject hasn't consented, so show the consent form.
           {$o->ensure_header;
            print slurp($o->{consent_path});
            print $o->form(sprintf '<div style="%s">%s<br>%s%s</div>',
                'text-align: center',
                '<input type="text" class="consent_statement" name="consent_statement" value="">',
                '<button type="submit" name="consent_button" value="submitted">OK</button>',
                !$o->{mturk} ? '' : hidden_inputs
                   (workerId => $p{workerId},
                    hitId => $p{hitId},
                    assignmentId => $p{assignmentId},
                    turkSubmitTo => $p{turkSubmitTo}));
            $o->quit;}}

    $o->ensure_header;
    $o->{completion_key} = $s{completion_key};
    $o->{cid} = $cookie->value;

    defined $o->{completion_key} and $o->completion_page;

    if ($o->{mturk} and $o->{mturk_prompt_new_window}
            and exists $p{workerId})
      # The subject probably just re-navigated to the task through
      # MTurk.
       {$o->prompt_new_window_page;}

    $ENV{REQUEST_METHOD} eq 'POST'
        and $o->{post_params} = \%p;
    $o->{user} = {map
        {$_->{k} => $_->{v}}
        $o->getrows('user', sn => $o->{sn})};
    $o->{timing} = {map
        {$_->{k} =>
           {first_sent => $_->{first_sent},
            received => $_->{received}}}
        $o->getrows('timing', sn => $o->{sn})};}

sub ensure_header
   {my $self = shift;
    $self->{printed_header} and return;
    print
        exists $self->{set_cookie}
          ? 'Set-Cookie: ' . $self->{set_cookie} . "\n"
          : '',
        "Content-Type: text/html; charset=utf-8\n",
        "\n",
        qq{<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN"\n},
        qq{    "http://www.w3.org/TR/html4/strict.dtd">\n},
        qq{<html lang="en">\n},
        "<head>\n",
        $self->{head},
        "</head>\n",
        "\n",
        "<body>\n\n\n";
    $self->{printed_header} = 1;}

sub save
   {my ($self, $key, $value) = @_;
    $self->replace('user',
        sn => $self->{sn}, k => $key, v => $value);
    $self->{user}{$key} = $value;}

sub getu
   {my ($self, $key) = @_;
    exists $self->{user}{$key}
        or die "getu on unset key: $key";
    $self->{user}{$key};}

sub existsu
   {my ($self, $key) = @_;
    exists $self->{user}{$key};}

sub randomly_assign
   {my ($self, $key, @vals) = @_;
    $self->save($key, randelm @vals);}

sub assign_permutation
   {my ($self, $key, $separator, @vals) = @_;
    $self->save($key, join $separator, shuffle @vals);}

sub image_button
   {my $self = shift;
    my %options =
       (image_url => undef, alt => undef, anchors => undef,
        example => 0, @_);
    defined $options{anchors} and @{$options{anchors}} != 2 and
         die 'anchors must have exactly 2 elements';
    return sprintf '<div class="image_button">%s%s%s</div>',
        $options{anchors}
          ? sprintf('<div class="anchor">%s</div>',
                htmlsafe $options{anchors}[0])
          : '',
        sprintf('<%s src="%s" alt="%s">',
            $options{example}
              ? 'img'
              : 'input type="image" name="image_button"',
            htmlsafe($options{image_url}),
            htmlsafe($options{alt})),
        $options{anchors}
          ? sprintf('<div class="anchor">%s</div>',
                htmlsafe $options{anchors}[1])
          : '';}

sub prompt_new_window_page
   {my $self = shift;
    print
      q!<script type="text/javascript">
        // From https://developer.mozilla.org/en/DOM/window.open#Best_practices
        var win = null;
        function new_win(url)
           {if (win == null || win.closed)
                win = window.open(url,
                    "mywin", "resizable=yes,scrollbars=yes,status=yes");
            else
                win.focus();};
        </script>!;
    printf '<p><a href="%s" %s %s>%s</a> %s</p>',
        htmlsafe $self->{here_url},
        'onclick="new_win(this.href); return false"',
        'onkeydown="new_win(this.href); return false"',
        'This HIT is best viewed in its own window or tab.',
        q{You may get a blank page when you submit the HIT, but don't be alarmed: it should still have gone through.};
    $self->quit;}

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
       (multiline => 0, max_chars => 256,
        trim => 1, accept_blank => 0,
        hint => undef, proc => undef,
        @_);
    # Note: hint, if provided, should be raw HTML, not
    # plain text.
    $self->page(key => $key,
        content => $content,
        fields =>
          [{name => 'text_entry',
                k => $key,
                html => sprintf('<div class="text_entry">%s%s</div>',
                  $options{multiline}
                    ? '<textarea class="text_entry" name="text_entry"></textarea>'
                    : '<input type="text" class="text_entry" name="text_entry">',
                  defined $options{hint}
                    ? sprintf '<div class="hint">%s</div>', $options{hint}
                    : ''),
                proc => sub
                   {if ($options{trim})
                       {s/\A\s+//;
                        s/\s+\z//;}
                    $options{accept_blank} or /\S/ or return;
                    if ($options{proc})
                       {$_ = $options{proc}->();
                        defined or return;}
                    substr $_, 0, $options{max_chars};}},
           {name => 'text_entry_submit_button',
                html => '<p><button class="next_button" name="text_entry_submit_button" value="submit" type="submit">OK</button></p>',
                proc => sub { $_ eq 'submit' or undef }}]);}

sub dollars_entry_page
   {my ($self, $key, $content) = @_;
    $self->text_entry_page($key, $content,
        hint => 'Enter a dollar amount. Cents are allowed.',
        proc => sub
           {/\A (?: \$ \s*)? (\d+ (?: \.\d\d?)? | \.\d\d? ) (?: \s* \$)? \z/x
              ? $1
              : undef});}

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

sub image_button_page
   {my ($self, $key, $content, %options) = @_;
    $self->page(key => $key,
        content => $content,
        fields =>
           [{name => 'image_button.x',
                k => "$key.x",
                html => $self->image_button(%options),
                proc => \&image_button_page_proc},
            {name => 'image_button.y',
                k => "$key.y",
                html => '',
                proc => \&image_button_page_proc}]);}

sub completion_page
   {my $self = shift;
    unless (defined $self->{completion_key})
       {$self->{completion_key} = rand_base64_str;
        $self->modify('subjects', {sn => $self->{sn}},
           {completion_key => $self->{completion_key},
            completed_t => time});}
    print $self->{experiment_complete};
    if ($self->{mturk})
      # Create a HIT-submission button.
       {my %r = $self->getrow('mturk', sn => $self->{sn});
        print sprintf '<form method="post" action="%s">%s%s</form>',
            htmlsafe($r{submit_to} . '/mturk/externalSubmit'),
            hidden_inputs
               (assignmentId => $r{assignmentid},
                hitId => $r{hitid},
                tversky_completion_key => $self->{completion_key}),
            '<button name="submit_hit_button" value="submitted" type="submit">Submit HIT</button>';}
    $self->quit;}

sub loop
   {my ($self, $key, $f) = @_;
    $self->existsu($key)
        or $self->save($key, 0);
    $_ = $self->getu($key);
    /\ALAST / and return;
    foreach my $UNUSED (1, 2)
       {eval {$f->()};
        if ($@)
           {if ($@ eq "LAST\n")
              {$self->save($key, "LAST $_");
               return;}
            die;}
        $self->save($key, ++$_);}
    die 'loop attempted to run more than twice for one request';}

sub last
   {die "LAST\n";}

sub quit
   {my $self = shift;
    print $self->{footer};
    exit;}

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
sub getitem
   {my ($self, $table, $expr, %where) = @_;
    scalar(($self->sel($table, $expr, \%where)->flat)[0])}
sub getrows
   {my ($self, $table, %where) = @_;
    $self->sel($table, '*', \%where)->hashes};
sub getrow
   {my ($self, $table, %where) = @_;
    %{ ($self->sel($table, '*', \%where)->hashes)[0] || {} };}
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

sub double_dipped_page
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
        if ($self->{post_params} and
                exists $self->{post_params}{key} and
                $self->{post_params}{key} eq htmlsafe($key))
           {my %to_save;
            foreach my $f (@{$h{fields}})
               {exists $self->{post_params}{$f->{name}} or last VALIDATE;
                local $_ = $self->{post_params}{$f->{name}};
                my $v = $f->{proc}->();
                defined $v or last VALIDATE;
                exists $f->{k} and $to_save{$f->{k}} = $v;}
            $self->transaction(sub
               {$self->save($_, $to_save{$_}) foreach keys %to_save;
                $self->now_done($key);});
            # Delete $self->{post_params} so responses to this
            # task aren't mistaken for responses to another task.
            delete $self->{post_params};
            return;}}}

    # Show the task.
    print "<div class='expbody'>$h{content}</div>";
    print $self->form(
        defined $key
          ? sprintf('<div><input type="hidden" name="key" value="%s"></div>',
                htmlsafe $key)
          : (),
        map {$_->{html}} @{$h{fields}});
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

1;
