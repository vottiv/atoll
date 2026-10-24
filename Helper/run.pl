use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "load";
my $fn = $ARGV[1];
my $sym = DynaLoader::dl_find_symbol($lib, $fn) or die "sym";
DynaLoader::dl_install_xsub("main::x", $sym);
&x();
