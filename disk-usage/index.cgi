#!/usr/bin/perl
# disk-usage/index.cgi - forwards to Primary Disk Usage (disk-focus).
#
# Authentic theme sends a click on the dashboard disk dial to /disk-usage when
# a module of that name is available, and to the Disk Quotas list otherwise.
# Webmin 2.670 ships no such module, so this hidden one claims the name and
# forwards, with no change to the theme. If an official disk-usage module ever
# arrives it replaces this, and the dial simply opens that instead.
# (fsn1, 2026-10-08)

BEGIN { push(@INC, ".."); };
use WebminCore;
&init_config();
&redirect("/disk-focus/");
