# -*- R -*-

# ----------------------------------------------------------

ordf = function(`_data`, ...)
# Similar to plyr::arrange, but preserves row names.
# Data = ordf(Data, FactorB, -FactorA, …)
   {m = match.call()
    `_data`[eval(as.call(c(quote(order), as.list(m)[c(-1, -2)])),
        `_data`, parent.frame()),]}

posix.ct = function(n)
# Converts a Unix time to a POSIXct.
    as.POSIXct(n, origin = "1970-1-1", tz = "UTC")

# ----------------------------------------------------------

tversky.sid = function(sn)
    sprintf("s%04d", sn)

unpack.tversky = function(db.path,
        include.incomplete = T, exclude.sns = numeric())
   {library(DBI)
    library(RSQLite)
    library(reshape2)

    db = dbConnect(dbDriver("SQLite"), dbname = db.path)

    subjects = dbGetQuery(db, '
      select Subjects.*,
          cast(began_t as float) as began_t,
          MTurk.hitid as hit, MTurk.assignmentid as asgmt, Mturk.workerid as worker
      from Subjects
          left join
              (select sn, min(first_sent) as began_t from Timing group by sn)
              using (sn)
          left join MTurk using (sn)')

    subjects = transform(subjects,
        task = factor(task, ordered = T, levels =
            unique(ordf(subjects, began_t)$task)))
      # This ensures that the levels of 'task' are in
      # chronological order.

    subjects = subset(subjects, !(sn %in% exclude.sns) &
        (include.incomplete | !is.na(completed_t)))
    subjects = cbind(
        s = tversky.sid(subjects$sn),
        subjects)
    row.names(subjects) = subjects$s
    subjects = transform(subjects,
        tv = NA,
        experimenter = factor(experimenter),
        ip = factor(ip),
        hit = factor(hit),
        asgmt = factor(asgmt),
        worker = factor(worker),
        consented_t = posix.ct(as.numeric(
            ifelse(consented_t == "assumed", NA, consented_t))),
        began_t = posix.ct(began_t),
        completed_t = posix.ct(as.numeric(completed_t)))
    subjects = transform(subjects,
        tv = as.integer(task))
          # "tv" for "task version"

    dlong = ordf(
        transform(subset(dbReadTable(db, "D"), sn %in% subjects$sn),
            k = factor(k)),
        sn)
    dlong = cbind(
        s = tversky.sid(dlong$sn),
        subset(dlong, select = -sn))
    dwide = ordf(dcast(dlong, s ~ k, value.var = "v"), s)
    row.names(dwide) = dwide$s

    timing = ordf(
        transform(
            subset(dbReadTable(db, "Timing"), sn %in% subjects$sn),
            k = factor(k),
            d = received - first_sent),
        sn, first_sent)
    timing = cbind(
        s = tversky.sid(timing$sn),
        subset(timing, select = -sn))
    tdiff = dcast(timing, s ~ k, value.var = "d")
    row.names(tdiff) = as.character(tdiff$s)

    subjects = subjects[c(
        "s", "experimenter", "ip",
        "hit", "asgmt", "worker",
        "task", "tv",
        "consented_t", "began_t", "completed_t")]
    list(
        subjects = subjects,
        dlong = dlong,
        dwide = dwide,
        timing = timing,
        tdiff = tdiff)}
