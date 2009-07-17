my %params = (
 mode => "my::kaas::full"
);
if ($params{mode} =~ /^(my::)([^:.]+)/) {
    my $class = $2;
my $mm = $1;
    printf STDERR "my own class is %s / %s\n", $class, $mm;
printf "matsch!!!!!!!!!!!!!\n";
    substr($class, 0, 1) = uc substr($class, 0, 1);
    printf STDERR "my own class is %s\n";
}
