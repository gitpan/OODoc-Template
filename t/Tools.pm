# Copyrights 2003,2007-2008 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.05.
use warnings;
use strict;

package Tools;
use vars '$VERSION';
$VERSION = '0.14';


use OODoc::Template;
use base 'Exporter';
use Test::More;

our @EXPORT = qw/do_process/;

sub do_process($@)
{   my $t   = shift;
    my ($out, $tree) = $t->process(@_);

    ok(defined $out);
    ok(defined $tree);
    isa_ok($tree, 'ARRAY');

    $out;
}

1;
