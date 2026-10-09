# disk-focus-lib.pl
# Shared helpers for the Primary Disk Usage module.
#
# Webmin's built-in "Local disk space" figure comes from mount::local_disk_space(),
# which sums every local filesystem and offers no way to exclude one. On a host with
# a small fast root disk and a large bulk volume that makes the headline number
# meaningless. This module reports only the mounts you nominate.

BEGIN { push(@INC, ".."); };
use WebminCore;
&init_config();

# list_focus_disks()
# Returns a list of hash refs for the mount points named in the module config,
# in the order they are configured. Each has: dir, device, type, total, used,
# free, used_percent. Mounts that are configured but not present are skipped.
sub list_focus_disks
{
my @want = &focus_mount_list();
return () if (!@want);

&foreign_require("mount");
my (undef, undef, $disks, undef) = &mount::local_disk_space();
return () if (!$disks || !@$disks);

my %bydir = map { $_->{'dir'}, $_ } @$disks;
my @rv;
foreach my $w (@want) {
	my $d = $bydir{$w};
	next if (!$d || !$d->{'total'});
	my $total = $d->{'total'};
	my $free  = $d->{'free'};
	# Same rule as the dashboard dial: root-reserved blocks count as used.
	my $used  = $total - $free;
	my $pc    = int($used / $total * 100);
	push(@rv, { 'dir'          => $d->{'dir'},
		    'device'       => $d->{'device'},
		    'type'         => $d->{'type'},
		    'total'        => $total,
		    'free'         => $free,
		    'used'         => $used,
		    'used_percent' => $pc });
	}
return @rv;
}

# focus_mount_list()
# The mount points this module reports on. Since 2026-10-08 the dashboard
# dial's own setting decides (Virtualmin's "Filesystems to include in local
# disk space", collect_fs, made to work by collect-fs-lib.pl), so this panel,
# this module's page and the dial always agree. The module's older 'mounts'
# setting is only the fallback when that one is unset.
sub focus_mount_list
{
my $lib = &module_root_directory("disk-focus")."/collect-fs-lib.pl";
if (-r $lib && &foreign_check("virtual-server")) {
	my %vc = &foreign_config("virtual-server");
	if ($vc{'collect_fs'} && do $lib) {
		my $w = collect_fs::wanted_dirs($vc{'collect_fs'});
		return sort keys %$w if ($w && %$w);
		}
	}
return split(/\s+/, $config{'mounts'} || '/');
}

# dial_counted_dirs(collect_fs, &fs-by-dir)
# The mount points the dashboard dial actually counts, as a hashref, or undef
# for "all of them". Mirrors collect_fs::apply exactly: when nothing chosen
# is a mounted filesystem with a size (e.g. a selected drive was swapped
# out), the dial falls back to every filesystem, so the page must say so too
# rather than marking everything "Not counted". Needs collect-fs-lib.pl.
sub dial_counted_dirs
{
my ($setting, $fs) = @_;
my $want = collect_fs::wanted_dirs($setting);
return undef if (!$want);
return undef if (!grep { $fs->{$_} && $fs->{$_}->{'total'} } keys %$want);
return $want;
}

# focus_totals(&disks)
# Returns (total, used, free, percent) summed across the given disks.
sub focus_totals
{
my ($disks) = @_;
my ($t, $u) = (0, 0);
foreach my $d (@$disks) {
	$t += $d->{'total'};
	$u += $d->{'used'};
	}
return (0, 0, 0, 0) if (!$t);
return ($t, $u, $t - $u, int($u / $t * 100));
}

1;
