my @isps = $B->isp_services;
for my $i (@isps) {
    print "debug: $i=>dev=",$B->dev($i),"\n";
}
