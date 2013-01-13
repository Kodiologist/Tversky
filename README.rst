Tversky is a Perl module for running psychology experiments on the Web, especially (but not exclusively) on Amazon Mechanical Turk. You use it to write a CGI script in an imperative style that serves as the task. SQLite is used both for session management and to store the data subjects provide.

You should take the absence of documentation as a hint that I'm not making any guarantees about stability. I wrote this thing for my own use. But see `Builder`_ for an example task.

As for security, Tversky should resist SQL-injection attacks and cross-site request forgery, but I haven't thought about race conditions much. You should run your CGI script in taint mode, of course.

The ``reserve_call`` method requires the ``call`` method of Rserve::Connection that I defined in `my fork of Rserve-perl`_.

Also included in this repository are:

``schema.sql``
    A schema for the SQLite database.

``unpack-tversky.R``
    R code for importing a Tversky database as a list of data frames.

``mturk-tversky-reconcile.py``
    A Python script that checks that workers who completed your task really were the workers they claimed to be. See, MTurk has no means of authenticating Worker IDs, so Tversky simply records whatever Worker ID is claimed and leaves it to you to reconcile the database against MTurk. The code in Tversky that prevents workers from doing the same task twice will only screen out workers with reconciled completed assignments. This means that, yes, it is possible for anybody to do the task by faking their Worker ID, but once they've submitted the assignment, you can see the real Worker ID and reject it, so there's no point from their perspective. Anyway, before running this script, be sure to set the environment variable ``BOTO_MTURK_CLI`` to the location of the ``mturk`` program from `my fork of boto`_.

Tversky is similar to but distinct from `SchizoidPy`_, which is a Python module to run psychology experiments locally. Tversky and SchizoidPy have different APIs because of the fundamental differences between web programming and application programming (which I, unlike a lot of people these days, am hardly eager to smooth over), but I've tried not to make them needlessly inconsistent.

Tversky is named for Amos Tversky, who died for our economic sins and deserved the Nobel just as much as Kahneman, dangit.

License
============================================================

This program is copyright 2012 Kodi Arfer.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the `GNU General Public License`_ for more details.

.. _`Builder`: https://github.com/Kodiologist/Builder
.. _`SchizoidPy`: https://github.com/Kodiologist/SchizoidPy
.. _`my fork of Rserve-perl`: https://github.com/Kodiologist/Rserve-perl
.. _`my fork of boto`: https://github.com/Kodiologist/boto
.. _`GNU General Public License`: http://www.gnu.org/licenses/