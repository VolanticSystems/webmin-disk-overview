#!/usr/bin/perl
# test-panel-numbers.pl - the module's own Dashboard panel must count used
# space the way the dial does: used = total - free (root-reserved blocks are
# used), percent = int(used / total * 100). Read-only. Run on fsn1.

BEGIN {
	push(@INC, "/usr/libexec/webmin");
	$ENV{'LIBROOT'} ||= "/usr/libexec/webmin";
	$ENV{'REMOTE_USER'} ||= 'root';
	$ENV{'BASE_REMOTE_USER'} ||= 'root';
	$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
	$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
	$0 = "/usr/libexec/webmin/disk-focus/index.cgi";
}
my $fails = 0;
sub check { my ($ok, $l, $d) = @_; printf("%s  %-44s %s\n", $ok ? 'PASS' : 'FAIL', $l, $d || ''); $fails++ if (!$ok); }

chdir("/usr/libexec/webmin/disk-focus") || die "chdir: $!";
# DF_LIB loads another copy of the library (e.g. a backup) as a control.
require($ENV{'DF_LIB'} || './disk-focus-lib.pl');
&foreign_require("mount");
my (undef, undef, $allfs) = &mount::local_disk_space();
my %fs = map { $_->{'dir'}, $_ } @$allfs;

my @disks = &list_focus_disks();
check(scalar(@disks) > 0, "panel has disks", join(' ', map { $_->{'dir'} } @disks));
foreach my $d (@disks) {
	my $s = $fs{$d->{'dir'}};
	my $u = $s->{'total'} - $s->{'free'};
	my $pc = int($u / $s->{'total'} * 100);
	check($d->{'used'} == $u && $d->{'used_percent'} == $pc,
	      "$d->{'dir'}: used = total - free, $pc%",
	      "got $d->{'used_percent'}%");
	}
my ($t, $u, $f, $pc) = &focus_totals(\@disks);
my ($st, $sf) = (0, 0);
foreach my $d (@disks) { $st += $fs{$d->{'dir'}}->{'total'}; $sf += $fs{$d->{'dir'}}->{'free'}; }
check($f == $sf && $pc == int(($st - $sf) / $st * 100),
      "panel totals: free is real free, $pc%");
print "\nfailures: $fails\n";
exit($fails ? 1 : 0);
