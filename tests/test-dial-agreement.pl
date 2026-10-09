#!/usr/bin/perl
# test-dial-agreement.pl - the page's Counted / Not counted badges must agree
# with what the dashboard dial really counts, for every kind of setting,
# including settings that match nothing (the dial then falls back to all).
#
# The dial side is collect_fs::apply, the code the system-status hook runs.
# The page side is dial_counted_dirs. For each setting, the total size of the
# filesystems the page marks Counted must equal the dial's disk_total.
# CONTROL: the page's formula before 2026-10-09 (wanted_dirs alone) is run
# through the same settings and must disagree on the ones that match nothing.
# Read-only; no setting is changed. Run on fsn1.

BEGIN {
	push(@INC, "/usr/libexec/webmin");
	$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
	$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
	$ENV{'REMOTE_USER'} ||= 'root';
	$0 = "/usr/libexec/webmin/disk-focus/index.cgi";
}
chdir("/usr/libexec/webmin/disk-focus") || die "chdir: $!";
require './disk-focus-lib.pl';
require './collect-fs-lib.pl';
&foreign_require("mount");
my (undef, undef, $allfs) = &mount::local_disk_space();
my %fs = map { $_->{'dir'}, $_ } @$allfs;

my $fails = 0;
sub check { my ($ok, $l, $d) = @_; printf("%s  %-50s %s\n", $ok ? 'PASS' : 'FAIL', $l, $d || ''); $fails++ if (!$ok); }

sub dial_total
{
my ($setting) = @_;
my %info = ( 'disk_fs' => [ map { { %$_ } } @$allfs ] );
$info{'disk_total'} = 0;
$info{'disk_total'} += $_->{'total'} foreach (@$allfs);
collect_fs::apply(\%info, $setting);
return $info{'disk_total'};
}

sub page_total
{
my ($w) = @_;
my $t = 0;
foreach my $d (keys %fs) {
	$t += $fs{$d}->{'total'} if (!$w || $w->{$d});
	}
return $t;
}

my @settings = ('', 'disks:nvme0n1 nvme1n1', 'disks:nvme0n1 nvme1n1 sda',
		'disks:sda', 'disks:sdz', '/', '/nope');
my $control_disagreed = 0;
foreach my $s (@settings) {
	my $dial = dial_total($s);
	my $page = page_total(&dial_counted_dirs($s, \%fs));
	check($page == $dial, "setting '$s': page agrees with dial",
	      &nice_size($page)." vs ".&nice_size($dial));
	my $old = page_total(collect_fs::wanted_dirs($s));
	$control_disagreed++ if ($old != $dial);
	}
check($control_disagreed >= 2, "CONTROL: old page formula disagrees",
      "$control_disagreed setting(s)");
print "\nfailures: $fails\n";
exit($fails ? 1 : 0);
