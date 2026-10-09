do 'disk-focus-lib.pl';

# list_system_info(&data, &in, &modskip)
# Contributes one dashboard panel showing usage for the nominated mounts only.
sub list_system_info
{
my @disks = &list_focus_disks();
return () if (!@disks);

&load_theme_library();

my ($total, $used, $free, $pc) = &focus_totals(\@disks);

# Warn colour thresholds match Webmin's own disk panel.
my $open = $pc >= 90 ? 1 : 0;

my @chart;
foreach my $d (@disks) {
	my $dpc = $d->{'used_percent'};
	push(@chart, {
		'desc'  => "<tt>$d->{'dir'}</tt>",
		'chart' => [ 100, $dpc, 0 ],
		'value' => &text('df_outof',
				 &nice_size($d->{'used'}),
				 &nice_size($d->{'total'}),
				 $dpc),
		});
	}

my $header;
if (@disks > 1) {
	$header = &text('df_header_multi', scalar(@disks),
			&nice_size($used), &nice_size($total), $pc);
	}
else {
	$header = &text('df_header_one', $disks[0]->{'dir'},
			&nice_size($free));
	}

return ({ 'type'   => 'chart',
	  'id'     => 'disk_focus',
	  'desc'   => $text{'df_title'},
	  'open'   => $open,
	  'header' => $header,
	  'chart'  => \@chart });
}

1;
