# collect-fs-lib.pl
# Makes Virtualmin's "Filesystems to include in local disk space" setting
# (virtual-server config key collect_fs) actually work. Webmin 2.670 and
# Virtualmin 8.2 show that setting but no code reads it, so the dashboard's
# disk dial always sums every local filesystem. (fsn1, 2026-10-08.)
#
# Loaded with "do" from two hooks, neither of which is ours:
#   system-status/system-status-lib.pl  collect_system_info()  -> apply()
#   virtual-server/config_info.pl       show_/parse_collect_fs -> show_field()/parse_field()
# Pure Perl plus /proc and /sys; no Webmin calls, so it runs in any package.
#
# collect_fs values:
#   ""                    all local filesystems (stock behaviour)
#   "/ /boot"             only these mount points (the original meaning)
#   "disks:nvme0n1 sda"   only filesystems that live entirely on these drives

package collect_fs;
use strict;
use warnings;
no warnings 'redefine';	# loaded with "do" from several hooks in one process

# base_disks(kernel-name) -> list of whole-disk kernel names under a block
# device, walking device-mapper/md slaves and partitions down to the drives.
sub base_disks
{
my ($k, $seen) = @_;
$seen ||= {};
return () if ($seen->{$k}++);
my $sys = "/sys/class/block/$k";
return () if (!-e $sys);
my @slaves;
if (opendir(my $dh, "$sys/slaves")) {
	@slaves = grep { !/^\./ } readdir($dh);
	closedir($dh);
	}
if (@slaves) {
	return map { base_disks($_, $seen) } @slaves;
	}
if (-e "$sys/partition") {
	my $real = readlink($sys) || '';
	$real =~ s{/[^/]+$}{};
	my ($parent) = $real =~ m{/([^/]+)$};
	return $parent ? base_disks($parent, $seen) : ();
	}
return ($k);
}

# device_kname(/dev/path) -> kernel name (dm-0, nvme0n1p2, md0 ...)
sub device_kname
{
my ($dev) = @_;
return undef if (!$dev || $dev !~ m{^/dev/});
my $real = $dev;
for (1 .. 10) {
	my $l = readlink($real);
	last if (!defined($l));
	$real = $l =~ m{^/} ? $l : do { (my $d = $real) =~ s{/[^/]+$}{}; "$d/$l" };
	}
$real =~ s{.*/}{};
return -e "/sys/class/block/$real" ? $real : undef;
}

# mounts() -> list of [ dir, device ] for real block-device mounts. A device
# mounted twice (a bind mount of a directory on /data, say) is listed
# once, at its first mount point, as Webmin's own disk totals do.
sub mounts
{
my (@rv, %seen);
open(my $fh, '<', '/proc/mounts') || return ();
while (my $l = <$fh>) {
	my ($dev, $dir) = split(/\s+/, $l);
	next if ($dev !~ m{^/dev/});
	next if ($seen{$dev}++);
	$dir =~ s/\\040/ /g;
	push(@rv, [ $dir, $dev ]);
	}
close($fh);
return @rv;
}

# raid_levels(kernel-name) -> md RAID levels found under a block device
sub raid_levels
{
my ($k, $seen) = @_;
$seen ||= {};
return () if ($seen->{$k}++);
my $sys = "/sys/class/block/$k";
my @rv;
my $lvl = read1("$sys/md/level");
push(@rv, $lvl) if ($lvl);
if (opendir(my $dh, "$sys/slaves")) {
	push(@rv, raid_levels($_, $seen)) foreach (grep { !/^\./ } readdir($dh));
	closedir($dh);
	}
return @rv;
}

# list_groups() -> drives that hold filesystems together, merged into one
# entry each, so a striped or mirrored set is chosen whole or not at all.
# Each: names [..], drives [..], ssd (1 if all SSD), mounts [ [dir, raid] ]
sub list_groups
{
my @drives = list_drives();
my %drv = map { $_->{'name'}, $_ } @drives;
my %parent = map { $_, $_ } keys %drv;
my $find;
$find = sub { my $x = shift;
	      $parent{$x} = $find->($parent{$x}) if ($parent{$x} ne $x);
	      return $parent{$x}; };
my @mnt;
foreach my $m (mounts()) {
	my $k = device_kname($m->[1]) || next;
	my %u = map { $_, 1 } grep { $drv{$_} } base_disks($k);
	my @b = sort keys %u;
	next if (!@b);
	$parent{$find->($_)} = $find->($b[0]) foreach (@b);
	my %lv = map { $_, 1 } raid_levels($k);
	push(@mnt, [ $m->[0], $b[0], join('+', map { uc($_) } sort keys %lv) ]);
	}
my %grp;
foreach my $n (sort keys %drv) {
	push(@{$grp{$find->($n)}->{'drives'}}, $drv{$n});
	}
foreach my $m (@mnt) {
	push(@{$grp{$find->($m->[1])}->{'mounts'}}, [ $m->[0], $m->[2] ]);
	}
my @rv;
foreach my $g (sort keys %grp) {
	my $e = $grp{$g};
	$e->{'names'} = [ map { $_->{'name'} } @{$e->{'drives'}} ];
	$e->{'ssd'} = (grep { !$_->{'ssd'} } @{$e->{'drives'}}) ? 0 : 1;
	$e->{'mounts'} ||= [ ];
	push(@rv, $e);
	}
return @rv;
}

sub read1
{
my ($f) = @_;
open(my $fh, '<', $f) || return '';
my $v = <$fh>;
close($fh);
$v = '' if (!defined($v));
$v =~ s/^\s+|\s+$//g;
return $v;
}

# list_drives() -> list of hashes: name, model, bytes, ssd (1/0), mounts [dirs]
sub list_drives
{
my %drv;
opendir(my $dh, '/sys/block') || return ();
foreach my $d (sort readdir($dh)) {
	next if ($d =~ /^(\.|loop|ram|zram|sr|fd|dm-|md)/);
	next if (!-e "/sys/block/$d/device");
	$drv{$d} = { 'name'  => $d,
		     'model' => read1("/sys/block/$d/device/model") ||
				read1("/sys/block/$d/device/name") || 'disk',
		     'bytes' => (read1("/sys/block/$d/size") || 0) * 512,
		     'ssd'   => read1("/sys/block/$d/queue/rotational") eq '0'
				? 1 : 0,
		     'mounts' => [ ] };
	}
closedir($dh);
foreach my $m (mounts()) {
	my $k = device_kname($m->[1]) || next;
	my %u = map { $_, 1 } base_disks($k);
	foreach my $b (sort keys %u) {
		push(@{$drv{$b}->{'mounts'}}, $m->[0]) if ($drv{$b});
		}
	}
return map { $drv{$_} } sort keys %drv;
}

# parse_value(collect_fs) -> ('all') | ('dirs', @dirs) | ('disks', @names)
sub parse_value
{
my ($v) = @_;
$v = '' if (!defined($v));
$v =~ s/^\s+|\s+$//g;
return ('all') if ($v eq '');
if ($v =~ s/^disks:\s*//) {
	return ('disks', split(/[\s,]+/, $v));
	}
return ('dirs', split(/\s+/, $v));
}

# wanted_dirs(collect_fs) -> hashref of mount dirs to count, or undef for all
sub wanted_dirs
{
my ($v) = @_;
my ($mode, @list) = parse_value($v);
return undef if ($mode eq 'all' || !@list);
return { map { $_, 1 } @list } if ($mode eq 'dirs');
my %want = map { $_, 1 } @list;
my %dirs;
foreach my $m (mounts()) {
	my $k = device_kname($m->[1]) || next;
	my @b = base_disks($k);
	next if (!@b);
	# Count a filesystem only if every drive under it was chosen.
	$dirs{$m->[0]} = 1 if (!grep { !$want{$_} } @b);
	}
return \%dirs;
}

# apply(&info, collect_fs)
# Recomputes disk_total/disk_free/disk_used from the chosen filesystems.
# disk_fs is left complete, so per-filesystem "nearly full" warnings still
# cover everything. If nothing matches, the stock totals are kept and
# disk_filter_error says why, rather than showing an empty or zero dial.
sub apply
{
my ($info, $v) = @_;
return if (!$info || !$info->{'disk_fs'});
my $want = wanted_dirs($v);
return if (!$want);
my ($t, $f, $u, $n) = (0, 0, 0, 0);
foreach my $fs (@{$info->{'disk_fs'}}) {
	next if (!$want->{$fs->{'dir'}});
	$t += $fs->{'total'} || 0;
	$f += $fs->{'free'} || 0;
	$u += $fs->{'used'} || 0;
	$n++;
	}
if (!$n || !$t) {
	$info->{'disk_filter_error'} =
		"collect_fs '$v' matched no mounted filesystem; showing all";
	return;
	}
$info->{'disk_total'} = $t;
$info->{'disk_free'}  = $f;
$info->{'disk_used'}  = $u;
$info->{'disk_filter'} = $v;
}

sub nice
{
my ($b) = @_;
my @u = ('B', 'KB', 'MB', 'GB', 'TB', 'PB');
my $i = 0;
while ($b >= 1000 && $i < $#u) { $b /= 1000; $i++; }
return sprintf($b >= 100 || $i == 0 ? "%d %s" : "%.1f %s", $b, $u[$i]);
}

sub esc
{
my ($s) = @_;
$s = '' if (!defined($s));
$s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
return $s;
}

# show_field(value) -> HTML for the settings form (field name collect_fs)
sub show_field
{
my ($v) = @_;
my ($mode, @list) = parse_value($v);
my %sel = map { $_, 1 } @list;
my $ck = sub { $_[0] eq $mode ? ' checked' : '' };
my $dirs = $mode eq 'dirs' ? join(' ', @list) : '';
my @groups = list_groups();
my $opts = '';
foreach my $g (@groups) {
	my @d = @{$g->{'drives'}};
	my %sz = map { nice($_->{'bytes'}), 1 } @d;
	my $size = keys(%sz) == 1 && @d > 1
		? scalar(@d)." &times; ".(keys %sz)[0]
		: join(' + ', map { nice($_->{'bytes'}) } @d);
	my $where = @{$g->{'mounts'}}
		? join(', ', map { esc($_->[0]).($_->[1] ? " ($_->[1])" : '') }
				 @{$g->{'mounts'}})
		: 'no mounted filesystems';
	my $all = !grep { !$sel{$_} } @{$g->{'names'}};
	$opts .= sprintf("<option value=\"%s\"%s>%s &mdash; %s, %s %s &mdash; %s</option>\n",
		esc(join(' ', @{$g->{'names'}})), $all ? ' selected' : '',
		esc(join(' + ', @{$g->{'names'}})),
		esc(join(' + ', map { $_->{'model'} } @d)),
		$size, $g->{'ssd'} ? 'SSD' : 'HDD', $where);
	}
my $rows = scalar(@groups) < 3 ? 3 : scalar(@groups);
return
  "<label><input type=radio name=collect_fs_mode value=all".$ck->('all').
  "> All local filesystems</label><br>\n".
  "<label><input type=radio name=collect_fs_mode value=dirs".$ck->('dirs').
  "> Listed mount points</label> ".
  "<input name=collect_fs_dirs size=30 value=\"".esc($dirs)."\"><br>\n".
  "<label><input type=radio name=collect_fs_mode value=disks".$ck->('disks').
  "> Only filesystems on this storage (drives used together are listed as one; Ctrl-click for several)</label><br>\n".
  "<select name=collect_fs_disks multiple size=$rows style=\"min-width:30em\">\n".
  $opts."</select>\n";
}

# parse_field(&in) -> new collect_fs value, or dies with a message.
# Called on Save, so it also drops the theme's cached dashboard: Authentic
# keeps its own copy of the dial figures and otherwise shows the old ones
# after a change.
sub parse_field
{
my ($in) = @_;
my $v = form_value($in);
forget_dashboard_cache();
return $v;
}

# forget_dashboard_cache([dir]) -> number of cache files removed.
# Authentic stores the dashboard per user in combined-system-info-<user> and
# rebuilds it, collecting fresh figures, when the file is missing.
sub forget_dashboard_cache
{
my ($dir) = @_;
$dir ||= ($main::var_directory || '/var/webmin').'/modules/authentic-theme';
my $n = 0;
foreach my $f (glob("$dir/combined-system-info-*")) {
	$n++ if (-f $f && unlink($f));
	}
return $n;
}

# form_value(&in) -> new collect_fs value from the form, or dies. No side effects.
sub form_value
{
my ($in) = @_;
my $mode = $in->{'collect_fs_mode'} || 'all';
if ($mode eq 'dirs') {
	my @d = grep { length } split(/\s+/, $in->{'collect_fs_dirs'} || '');
	@d || die "Enter at least one mount point, or choose another option\n";
	foreach my $x (@d) {
		$x =~ m{^/} || die "'$x' is not an absolute mount point\n";
		}
	return join(' ', @d);
	}
if ($mode eq 'disks') {
	# Each selected entry is a whole storage group: "nvme0n1 nvme1n1".
	my %u;
	my @d = grep { length && !$u{$_}++ }
		map { split(/\s+/) } split(/\0/, $in->{'collect_fs_disks'} || '');
	@d || die "Select at least one entry, or choose another option\n";
	my %ok = map { $_->{'name'}, 1 } list_drives();
	foreach my $x (@d) {
		$ok{$x} || die "'$x' is not a drive on this system\n";
		}
	return 'disks:'.join(' ', @d);
	}
return '';
}

1;
