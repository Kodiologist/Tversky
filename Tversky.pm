package Tversky;

use strict;

use parent 'Exporter';
our %EXPORT_TAGS;

use Config;
use DBIx::Simple;
use SQL::Abstract;
use CGI::Minimal;
use CGI::Cookie;
use HTML::Entities 'encode_entities';
use File::Slurp 'slurp';
use Digest::SHA 'sha256_base64';

# --------------------------------------------------
# Public subroutines
# --------------------------------------------------

our @EXPORT_OK = qw(cat htmlsafe randint randelm shuffle FREE_RESPONSE);

sub cat
   {join '', @_}

sub htmlsafe ($)
   {encode_entities $_[0], q(<>&"')}

my $urandom_fh;
sub randint ()
   {defined $urandom_fh
        or open $urandom_fh, '<:raw', '/dev/urandom';
    my $buffer;
    if ($Config{ivsize} >= 8)
      # We have 64-bit integers, so return one. (SQLite integers
      # are always 64-bit.)
       {read $urandom_fh, $buffer, 8;
        unpack 'q', $buffer;}
    else
      # Return a 32-bit integer.
       {read $urandom_fh, $buffer, 4;
        unpack 'l', $buffer;}}

sub randelm
   {$_[ int(rand() * @_) ]}

sub shuffle
   {my @a = @_;
    foreach my $n (1 .. $#a)
       {my $k = int rand $n + 1;
        $k == $n or @a[$k, $n] = @a[$n, $k];}
    return @a;}

use constant FREE_RESPONSE => [];
sub is_FREE_RESPONSE {ref($_[0]) and ref($_[0]) eq 'ARRAY' and @{$_[0]} == 0}

$EXPORT_TAGS{table_names} = [qw(SUBJECTS USER TIMING MTURK CONDITIONS)];
use constant SUBJECTS => 'Subjects';
use constant USER => 'D';
use constant TIMING => 'Timing';
use constant MTURK => 'MTurk';
use constant CONDITIONS => 'Conditions';

# --------------------------------------------------
# Private subroutines
# --------------------------------------------------

use constant HTTP_OK => '200 OK';
use constant HTTP_CANTDOTHAT => '422 Unprocessable Entity'; 
use constant HTTP_FORBIDDEN => '403 Forbidden';
use constant HTTP_MYFAULT => '500 Internal Server Error';

my $sql_abstract = new SQL::Abstract;

our %pp;
  # This gets bound to all post parameters inside 'proc' subs.

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

sub measurement_entry_proc
   {my ($str, $unit_reader) = @_;
    $str =~ /[[:alpha:]]\.\d/
      # Ambiguous: does "2lbs.3oz" mean 2 lbs 3 oz or
      # 2 lbs 0.3 oz?
        and return undef;
    # Now we can safely remove all periods after units.
    $str =~ s/([[:alpha:]])\./$1/g;
    # Remove plus signs, spaces, commas, and the word "and".
    $str =~ s/ +and +//g;
    $str =~ s/[ +,]//g;
    # Now try to interpret what's left.
    my $sum;
    while ($str =~ s/\A (\d+ | \d*\.\d+ ) ([[:alpha:]]+) //gx)
       {my ($x, $u) = ($1, $unit_reader->($2));
        defined $u or return undef;
        $sum += $x * $u;}
    # The input should be empty now.
    length($str) and return undef;
    return $sum;}

sub length_reader
   {my $str = lc(shift);
        in($str, qw(m ms meter meters metre metres))
      ? 1
      : in($str, qw(cm cms centimeter centimeters centimetre centimetres))
      ? .01
      : in($str, qw(mm mms millimeter millimeters millimetre millimetres))
      ? .001
      : in($str, qw(ft foot feet foots))
      ? .3048
      : in($str, qw(in ins inch inches inchs))
      ? .0254
      : undef}

sub mass_reader
   {my $str = lc(shift);
        in($str, qw(kg kgs kilogram kilograms kilogramme kilogrammes))
      ? 1
      : in($str, qw(g gs gram grams gramme grammes))
      ? .001
      : in($str, qw(mg mgs milligram milligrams milligramme milligrammes))
      ? 1e-6
      : in($str, qw(lb lbs pound pounds))
      ? 0.45359237
      : in($str, qw(oz ozs ounce ounces))
      ? (0.45359237 / 16)
      : undef}

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

         password_hash => undef,
         password_salt => undef,

         database_path => undef,

         consent_path => undef,
         consent_regex => qr/\A \s* ['"]? \s* i \s+ consent \s* ['"]? \s* \z/xi,

         mturk_prompt_new_window => 0,

         experiment_complete => '<p>The experiment is complete. Thanks for your help!</p>',

         task => undef,
         preview => sub { print '<p>(No preview available.)</p>' },
         after_consent_prep => sub {},

         head => '<title>Study</title>',
         footer => "</body></html>\n",

         rserve_host => 'localhost',
         @_);
    my $o = bless \%h, ref($invocant) || $invocant;

    if (defined $o->{password_hash})
       {$o->{password_salt}
            or die 'No salt defined';
        $o->{assume_consent}
            or die 'password_hash without assume_consent is not implemented';}

    $o;}

sub run
   {my ($self, $f) = @_;
    local $@;
    eval
       {$self->init;
        $f->();
        $self->completion_page;};
    $self->ensure_header(HTTP_MYFAULT);
    defined $@ or $@ = 'Exited "run" with undefined $@';
    $@ eq '' and $@ = 'Exited "run" with $@ set to the null string';
    warn $@;
    printf '<p>Error:</p><pre>%s</pre><p>Please report this.</p>',
        htmlsafe $@;
    $self->quit;}

sub init
   {my $o = shift;

    $o->{db} = DBIx::Simple->connect("dbi:SQLite:dbname=$o->{database_path}", '', '',
       {RaiseError => 1,
        sqlite_unicode => 1,
        sqlite_see_if_its_a_number => 1});
    $o->sql('pragma foreign_keys = on');

    if ($ENV{REQUEST_METHOD} eq 'POST')
       {defined $ENV{HTTP_REFERER}
            or die 'Possible XSRF attempt: POST with no referer';
        $ENV{HTTP_REFERER} =~ m!\A\Q$o->{here_url}\E(?:\z|\?|/)!
            or die "Possible XSRF attempt: POST with referer $ENV{HTTP_REFERER} (needed: $o->{here_url})";}

    my %p = do 
       {my $cgi = new CGI::Minimal;
        map {$_ => $cgi->param($_)} $cgi->param};

    my ($chosen_sn, $experimenter);
    if (exists $p{NEW_SUBJECT} and defined $o->{password_hash})
       {BLOCK:
           {my ($code, $msg) =
                $ENV{REQUEST_METHOD} ne 'POST' || !exists $p{password}
              ? (HTTP_OK, '')
              : sha256_base64($o->{password_salt} . $p{password}) ne $o->{password_hash}
              ? (HTTP_FORBIDDEN, 'Bad credentials.')
              : $p{sn} !~ /\A\d+\z/
              ? (HTTP_CANTDOTHAT, 'The given subject number is not an integer.')
              : $o->count(SUBJECTS, sn => $p{sn})
              ? (HTTP_CANTDOTHAT, 'That subject number is already taken. Pick a different one.')
              : last BLOCK;
            $o->ensure_header($code);
            $msg and print '<p><strong>Error:</strong> ', $msg, '</p>';
            print $o->form(
                sprintf('<p style="text-align: left">%s</p>', join '<br>',
                    '<label>Experimenter: <input type="text" name="experimenter" value=""></label>',
                    '<label>Password: <input type="password" name="password" value=""></label>',
                    '<label>Subject number (must be an integer): <input type="text" name="sn" value=""></label>'),
                '<p><button type="submit" name="NEW_SUBJECT" value="start">Start Task</button></p>');
            $o->quit;}
        $chosen_sn = $p{sn};
        $experimenter = $p{experimenter};}

    my $cookie;
       {my %h = CGI::Cookie->fetch;
        %h and $cookie = $h{'Tversky_ID_' . $o->{cookie_name_suffix}};}
    my %s;
    if (defined $cookie)
       {%s = $o->getrow(SUBJECTS, cookie_id => $cookie->value);
        $o->{sn} = $s{sn};}
    unless (defined $cookie
            and !defined $chosen_sn
            and %s and time <= $s{cookie_expires_t}
            and !($o->{mturk}
                and exists $p{workerId}
                and $p{workerId} ne $o->getitem(MTURK, 'workerid', sn => $s{sn})))

       {if ($o->{mturk} and !exists $p{workerId} || !exists $p{assignmentId} || !exists $p{hitId} || !exists $p{turkSubmitTo})
          # The worker is previewing this HIT. Or at any rate,
          # they haven't shown us a good cookie but nor have they
          # provided all four of the MTurk parameters, so we
          # might as well just show a preview.
           {$o->ensure_header;
            $o->{preview}->($o);
            $o->quit;}

        elsif ($o->{mturk} and $o->count(MTURK,
                workerid => $p{workerId},
                -bool => 'reconciled'))
          # The worker that this user is claiming to be has
          # already done this task (or has been included in the
          # MTurk table to keep them out of it).
           {$o->ensure_header;
            $o->double_dipped_page;}

        elsif (defined $o->{password_hash} and not defined $chosen_sn)
           {$o->ensure_header(HTTP_FORBIDDEN);
            print '<p>Access denied.</p>';
            $o->quit;}

        elsif ($o->{assume_consent}
                or $ENV{REQUEST_METHOD} eq 'POST'
                   and $p{consent_statement}
                   and $p{consent_statement} =~ $o->{consent_regex})
          # The subject just consented. Give them a cookie
          # and set up the experiment.
           {my $cid = randint;
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
               {$o->insert(SUBJECTS,
                    sn => $chosen_sn,
                      # Generally, $chosen_sn will be undefined,
                      # which is fine: SQLite will choose a subject
                      # number for us.
                    experimenter => $experimenter,
                    cookie_id => $cid,
                    cookie_expires_t => $cookie_expires_t,
                    ip => $ENV{REMOTE_ADDR},
                    consented_t => $o->{assume_consent}
                      ? 'assumed'
                      : time ,
                    task => $o->{task});
                %s = $o->getrow(SUBJECTS, cookie_id => $cid);
                $o->{sn} = $s{sn};
                $o->{mturk} and $o->insert(MTURK,
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

    $o->cache_tables;}

sub ensure_header
   {my ($self, $response_code) = @_;
    $self->{printed_header} and return;
    print
        'Status: ', ($response_code || HTTP_OK), "\n",
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
    $self->replace(USER,
        sn => $self->{sn}, k => $key, v => $value);
    $self->{user}{$key} = $value;}

sub sn
   {my $self = shift;
    $self->{sn};}

sub getu
   {my ($self, $key) = @_;
    exists $self->{user}{$key}
        or die "getu on unset key: $key";
    $self->{user}{$key};}

sub maybe_getu
   {my ($self, $key) = @_;
    $self->{user}{$key};}

sub existsu
   {my ($self, $key) = @_;
    exists $self->{user}{$key};}

sub save_once
   {my ($self, $key, $f) = @_;
    unless ($self->existsu($key))
       {my $value = $f->();
        my $inserted = $self->maybe_insert(USER,
            sn => $self->{sn}, k => $key, v => $value);
        if ($inserted)
           {$self->{user}{$key} = $value;}
        else
          # Somebody else inserted a row for this key while
          # $f was running.
           {$self->cache_tables;}}
    $self->getu($key);}

sub save_once_atomic
# Like save_once, but $f is executed inside a transaction.
   {my ($self, $key, $f) = @_;
    $self->existsu($key) or $self->transaction(sub
       {my ($row) = $self->getrows(USER, sn => $self->{sn}, k => $key);
        if ($row)
           {# Somebody else inserted a row for this key
            # between the $self->existsu($key) and the database
            # lock.
            $self->cache_tables;}
        else
           {$self->save($key, $f->());}});
    $self->getu($key);}

sub rserve_call
   {my ($self, $fun, @args) = @_;
    $self->init_rserve;
    $self->{rserve}->call($fun, @args);}

sub randomly_assign
   {my ($self, $key, @vals) = @_;
    $self->existsu($key)
        or $self->save($key, randelm @vals);}

sub assign_permutation
   {my ($self, $key, $separator, @vals) = @_;
    $self->existsu($key)
        or $self->save($key, join $separator, shuffle @vals);}

sub get_condition
# Pick a new condition for this subject from the conditions
# table, or, if one has already been assigned, return that.
   {my ($self, $key) = @_;
    $self->save_once($key, sub
      # Claim the least unused condition number (cn) for this key.
       {$self->modify(CONDITIONS,
           {cn => do
               {my ($stmt, @bind) = $sql_abstract->select(CONDITIONS,
                    'min(cn)',
                    {k => $key, sn => undef});
                \ ["= ($stmt)", @bind]}},
           {sn => $self->{sn}});
        $self->getitem(CONDITIONS, 'v',
            sn => $self->{sn}, k => $key);});}

sub image_button
   {my $self = shift;
    my %options =
       (image_url => undef, alt => undef, anchors => undef,
        bump => '0', example => 0, @_);
    defined $options{anchors} and @{$options{anchors}} != 2 and
         die 'anchors must have exactly 2 elements';
    return sprintf '<div class="image_button" style="%s">%s%s%s</div>',
        "padding-top: $options{bump}",
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
                    ? '<textarea class="text_entry" name="text_entry" rows="3" cols="30"></textarea>'
                    : "<input type='text' maxlength='$options{max_chars}' class='text_entry' name='text_entry'>",
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

sub nonneg_int_entry_page
   {my ($self, $key, $content) = @_;
    $self->text_entry_page($key, $content,
        hint => 'Enter a whole number.',
        proc => sub
           {s/,//g;
            /\A(\d+)\z/
              ? $1
              : undef});}

sub percent_entry_page
# Note that the entry is stored as a proportion of 1, not 100.
   {my ($self, $key, $content) = @_;
    $self->text_entry_page($key, $content,
        hint => 'Enter a percentage.',
        proc => sub
           {/\A (
                    (?<whole> \d+) |
                    (?<whole> \d*) \s* \. \s* (?<frac> \d+) )
                (?: \s* % )? \z/x or return undef;
            if ($+{whole} > 99)
               {$+{whole} == 100 or return undef;
                $+{frac} > 0 and return undef;
                return 1;}
            "$+{whole}.$+{frac}" / 100});}

sub dollars_entry_page
   {my ($self, $key, $content) = @_;
    $self->text_entry_page($key, $content,
        hint => 'Enter a dollar amount. Cents are allowed.',
        proc => sub
           {s/,//g;
            /\A (?: \$ \s*)? (\d+ (?: \.\d\d?)? | \.\d\d? ) (?: \s* \$)? \z/x
              ? $1
              : undef});}

sub length_entry_page
# The length is stored in meters.
   {my ($self, $key, $content) = @_;
    $self->text_entry_page($key, $content,
        hint => 'Enter a length, including a unit (such as "m" or "ft"; multi-unit sums like "1 ft 3 in" are allowed).',
        proc => sub {measurement_entry_proc($_, \&length_reader)});}

sub weight_entry_page
# The weight is stored in kilograms.
   {my ($self, $key, $content) = @_;
    $self->text_entry_page($key, $content,
        hint => 'Enter a weight, including a unit (such as "pounds" or "kg").',
        proc => sub {measurement_entry_proc($_, \&mass_reader)});}

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

my $multiple_choice_fr_max_chars = 1024;

sub multiple_choice_page
   {my ($self, $key, $content, @choices) = @_;
    @choices = map2
        {ref $_[0] ? ($_[0], $_[1]) : ([$_[0], $_[0]], $_[1])}
        @choices;
    $self->page(key => $key,
        content => $content,
        fields => [{name => 'multiple_choice',
            k => $key,
            html => sprintf('<div class="multiple_choice_box">%s</div>', join "\n",
                map2
                   {my ($value, $label) = @{shift()};
                    my $body = shift;
                    sprintf '<div class="row">%s%s</div>',
                        sprintf('<div class="button"><button name="multiple_choice" value="%s" type="submit">%s</button></div>',
                            htmlsafe($value), htmlsafe($label)),
                        sprintf('<div class="body">%s</div>', is_FREE_RESPONSE($body)
                          ? sprintf('<input type="text" maxlength="%s" class="text_entry" name="multiple_choice_fr.%s" value="">',
                                $multiple_choice_fr_max_chars,
                                htmlsafe($value))
                          : $body)}
                @choices),
            proc => sub
               {foreach my $i (0 .. int(@choices/2) - 1)
                   {my $value = $choices[2*$i][0];
                    my $body = $choices[2*$i + 1];
                    $_ eq $value or next;
                    is_FREE_RESPONSE($body) or return $value;
                    my $input = $pp{"multiple_choice_fr.$value"};
                    defined $input or return undef;
                    $input =~ s/\A\s+//;
                    $input =~ s/\s+\z//;
                    $input eq '' and return undef;
                    $input = substr $input, 0, $multiple_choice_fr_max_chars;
                    return "[FR] $input";}
                undef;}}]);}

my @generic_labels = ('A' .. 'Z');

sub shuffled_multiple_choice_page
   {my ($self, $key, $content, %choices) = @_;
    keys(%choices) > @generic_labels and die 'Not enough generic labels';
    my @permutation = defined $key
      ? do
         {$self->assign_permutation("$key.permutation", ',', keys %choices);
          split qr/,/, $self->getu("$key.permutation");}
      : # When $key is undefined, we can't touch the database,
        # but we don't have to be consistent, either.
        shuffle keys %choices;
    my $i = 0;
    $self->multiple_choice_page($key, $content, map
        {[$_, $generic_labels[$i++]] => $choices{$_}}
        @permutation);}

sub buttons_page
   {my ($self, $key, $content, @buttons) = @_;
    $self->multiple_choice_page($key, $content, map {$_, ''} @buttons);}

sub image_button_page
   {my ($self, $key, $content, %options) = @_;
    if (exists $options{bump})
      # Add a margin ($options{bump}, which is a CSS value for a
      # margin) to the button for every other image_button_page.
      # This keeps subjects from just clicking again without
      # moving the mouse.
       {if (not $self->existsu("$key.bump"))
           {$self->save_once('TVERSKY.prev_bump', sub {'Yes'});
            my $bump_now = $self->getu('TVERSKY.prev_bump') eq 'No';
            $self->save("$key.bump", $bump_now
              ? $options{bump}
              : '0');
            $self->save('TVERSKY.prev_bump', $bump_now
              ? 'Yes'
              : 'No');}
        $options{bump} = $self->getu("$key.bump");}
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

sub checkboxes_page
   {my ($self, $key, $content, @choices) = @_;
    $self->page(key => $key,
        content => $content,
        fields_wrapper => '<div class="checkboxes_box">%s</div>',
        fields =>
           [(map2
               {my ($value, $body) = @_;
                {name => "checkbox.$value",
                    k => "$key.$value",
                    optional => 1,
                    html => sprintf('<div class="row"><label>%s%s</label></div>',
                        "<input type='checkbox' name='checkbox.$value'>",
                        $body),
                    proc => sub {$_ ? 1 : 0}}}
                @choices),
            {name => 'checkboxes_page_submit_button',
                html => '<p><button class="next_button" name="checkboxes_page_submit_button" value="submit" type="submit">OK</button></p>',
                proc => sub { $_ eq 'submit' or undef }}]);}

sub completion_page
   {my $self = shift;
    unless (defined $self->{completion_key})
       {$self->{completion_key} = randint;
        $self->modify(SUBJECTS, {sn => $self->{sn}},
           {completion_key => $self->{completion_key},
            completed_t => time});}
    print $self->{experiment_complete};
    if ($self->{mturk})
      # Create a HIT-submission button.
       {my %r = $self->getrow(MTURK, sn => $self->{sn});
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
    local $_ = $self->getu($key);
    /\ADONE / and return;
    foreach my $UNUSED (1, 2)
       {eval {$f->()};
        if ($@)
           {if ($@ =~ /\ADONE(\d*)\Z/)
              {$self->save($key, 'DONE ' . (length($1) ? $1 : $_ + 1));
               return;}
            die;}
        $self->save($key, ++$_);}
    die 'loop attempted to run more than twice for one request';}

sub get_loop_iters
# Returns the number of completed iterations of the given loop.
   {my ($self, $key) = @_;
    my $v = $self->maybe_getu($key);
    defined $v
      ? $v =~ /\ADONE (\d+)/
        ? $1
        : $v
      : 0}

sub done
   {my ($self, $iterations_completed) = @_;
    die sprintf "DONE%s\n", defined $iterations_completed
      ? $iterations_completed
      : '';}

sub quit
   {my $self = shift;
    print $self->{footer};
    exit;}

# --------------------------------------------------
# Private methods
# --------------------------------------------------

sub sql
   {my $self = shift;
    $self->{db}->query(@_)}

sub sel
   {my $self = shift;
    $self->{db}->select($_[0], @_[1 .. $#_])}

sub modify
   {my ($self, $table, $where, $update) = @_;
    $self->{db}->update($table, $update, $where);}
sub insert
   {my ($self, $table, %fields) = @_;
    $self->{db}->insert($table, \%fields);}
sub maybe_insert
# Like "insert" above, but uses SQLite's INSERT OR IGNORE.
# Returns 1 if a row was inserted, 0 otherwise.
   {my ($self, $table, %fields) = @_;
    my ($statement, @bind) = $sql_abstract->insert($table, \%fields);
    $statement =~ s/\AINSERT /INSERT OR IGNORE /i or die 'insert-or-ignore';
    $self->sql($statement, @bind)->rows;}
sub replace
# Like "insert" above, but uses SQLite's INSERT OR REPLACE.
   {my ($self, $table, %fields) = @_;
    my ($statement, @bind) = $sql_abstract->insert($table, \%fields);
    $statement =~ s/\AINSERT /INSERT OR REPLACE /i or die 'insert-or-replace';
    $self->sql($statement, @bind);}
sub getitem
   {my ($self, $table, $expr, %where) = @_;
    scalar(($self->sel($table, $expr, \%where)->flat)[0])}
sub getrows
   {my ($self, $table, %where) = @_;
    $self->sel($table, '*', \%where)->hashes;}
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

sub cache_tables
   {my $self = shift;
    $self->{user} = {map
        {$_->{k} => $_->{v}}
        $self->getrows(USER, sn => $self->{sn})};
    $self->{timing} = {map
        {$_->{k} =>
           {first_sent => $_->{first_sent},
            received => $_->{received}}}
        $self->getrows(TIMING, sn => $self->{sn})};}

sub init_rserve
   {my $self = shift;
    unless (exists $self->{rserve})
       {require Rserve::Connection;
        $self->{rserve} = new Rserve::Connection($self->{rserve_host}) or die;
        Rserve::Connection->init;}
    return 1;}

sub double_dipped_page
   {my $self = shift;
    print "<p>It looks like you participated in another study that makes you ineligible for this one (perhaps the same study as a different HIT). Please return this HIT.</p>";
    $self->quit;}

sub page
   {my $self = shift;
    my %h =
       (key => undef, content => undef,
        fields_wrapper => '%s', fields => [],
        @_);
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
                $self->{post_params}{key} eq $key)
           {my %to_save;
            local *pp = $self->{post_params};
            foreach my $f (@{$h{fields}})
               {$f->{optional} or exists $pp{$f->{name}} or last VALIDATE;
                local $_ = $pp{$f->{name}};
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
        sprintf $h{fields_wrapper}, join '',
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
        $self->insert(TIMING,
            sn => $self->{sn},
            k => $key,
            first_sent => $self->{timing}{$key}{first_sent});}
    return 1;}

sub now_done
   {my ($self, $key) = @_;
    $self->{timing}{$key}{received} = time;
    $self->modify(TIMING,
        {sn => $self->{sn}, k => $key},
        {received => $self->{timing}{$key}{received}});}

# --------------------------------------------------
# End
# --------------------------------------------------

push @EXPORT_OK, @$_
    foreach values %EXPORT_TAGS;

1;
