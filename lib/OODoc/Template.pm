# Copyrights 2003,2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.02.
use strict;
use warnings;

package OODoc::Template;
use vars '$VERSION';
$VERSION = '0.1';

use IO::File   ();
use Data::Dumper;

my @default_markers = ('<!--{', '}-->', '<!--{/', '}-->');


sub new(@)
{   my ($class, %args) = @_;
    (bless {}, $class)->init(\%args);
}

sub init($)
{   my ($self, $args) = @_;

    $self->{cached}     = {};
    $self->{macros}     = {};

    $args->{template} ||= sub { $self->includeTemplate(@_) };
    $args->{macro}    ||= sub { $self->defineMacro(@_) };
    $args->{search}   ||= '.';
    $args->{markers}  ||= \@default_markers;
    $args->{define}   ||= sub { +{} };

    $self->pushValues($args);
    $self;
}


sub process($)
{   my ($self, $templ) = (shift, shift);

    my $values = @_==1 ? shift : @_ ? {@_} : {};

    my $tree     # parse with real copy
      = ref $templ eq 'SCALAR' ? $self->parseTemplate($$templ)
      : ref $templ eq 'ARRAY'  ? $templ
      :                          $self->parseTemplate("$templ");

    $self->pushValues($values) if keys %$values;

    my @output;
    foreach my $node (@$tree)
    {   unless(ref $node)
        {   push @output, $node;
            next;
        }
    
        my ($tag, $attr, $then, $else) = @$node;

        my %attrs;
        while(my($k, $v) = each %$attr)
        {   $attrs{$k} = ref $v ne 'ARRAY' ? $v
              : join '',
                   map {ref $_ eq 'ARRAY' ? scalar $self->valueFor(@$_) : $_}
                      @$v;
        }

        my $value = $self->valueFor($tag, \%attrs, $then, $else);
        unless(defined $then || defined $else)
        {   push @output, $value if defined $value;
            next;
        }

        my $take_else
           = !defined $value || (ref $value eq 'ARRAY' && @$value==0);

        my $container = $take_else ? $else : $then;

        defined $container
            or next;

        $self->pushValues(\%attrs) if keys %attrs;

        if($take_else)
        {    my ($nest_out, $nest_tree) = $self->process($container);
             push @output, $nest_out;
             $node->[3] = $nest_tree;
        }
        elsif(ref $value eq 'HASH')
        {    my ($nest_out, $nest_tree) = $self->process($container, $value);
             push @output, $nest_out;
             $node->[2] = $nest_tree;
        }
        elsif(ref $value eq 'ARRAY')
        {    foreach my $data (@$value)
             {   my ($nest_out, $nest_tree) = $self->process($container, $data);
                 push @output, $nest_out;
                 $node->[2] = $nest_tree;
             }
        }
        else { die "only HASH or ARRAY values can control a loop ($tag)\n" }

        $self->popValues if keys %attrs;
    }
    
    $self->popValues if keys %$values;

              wantarray ? (join('', @output), $tree)  # LIST context
    : defined wantarray ? join('', @output)           # SCALAR context
    :                     print @output;              # VOID context
}


sub processFile($;@)
{   my ($self, $filename) = (shift, shift);

    my $values = @_==1 ? shift : {@_};
    $values->{source} ||= $filename;

    my $template;
    if(exists $self->{cached}{$filename})
    {   $template = $self->{cached}{$filename}
            or return ();
    }
    else
    {   $template = $self->loadFile($filename);
    }

    my ($output, $tree) = $self->process($template, $values);
    $self->{cached}{$filename} = $tree;

              wantarray ? ($output, $tree)  # LIST context
    : defined wantarray ? $output           # SCALAR context
    :                     print $output;    # VOID context
}


sub defineMacro($$$$)
{   my ($self, $tag, $attrs, $then, $else) = @_;
    my $name = $attrs->{name}
        or die "ERROR: macro requires a name\n";

    defined $else
        and die "ERROR: macros cannot have an else part ($name)\n";

    my %attrs = %$attrs;   # for closure
    $attrs{markers} = $self->valueFor('markers');

    $self->{macros}{$name} =
        sub { my ($tag, $at) = @_;
              $self->process($then, +{%attrs, %$at});
            };

    ();
    
}


sub valueFor($;$$$)
{   my ($self, $tag, $attrs, $then, $else) = @_;

#warn "Looking for $tag";
#warn Dumper $self->{values};
    for(my $set = $self->{values}; defined $set; $set = $set->{NEXT})
    {   
        my $v = $set->{$tag};

        if(defined $v)
        {   # HASH  defines container
            # ARRAY defines container loop
            # object or other things can be stored as well, but may get
            # stringified.
            return wantarray ? ($v, $attrs, $then, $else) : $v
                if ref $v ne 'CODE';

            return wantarray
                 ? $v->($tag, $attrs, $then, $else)
                 : ($v->($tag, $attrs, $then, $else))[0]
        }

        my $code = $set->{DYNAMIC};
        if(defined $code)
        {   my ($value, @other) = $code->($tag, $attrs, $then, $else);
            return wantarray ? ($value, @other) : $value
                if defined $value;
            # and continue the search otherwise
        }
    }

    ();
}


sub allValuesFor($;$$$)
{   my ($self, $tag, $attrs, $then, $else) = @_;
    my @values;

    for(my $set = $self->{values}; defined $set; $set = $set->{NEXT})
    {   
        if(defined(my $v = $set->{$tag}))
        {   my $t = ref $v eq 'CODE' ? $v->($tag, $attrs, $then, $else) : $v;
            push @values, $t if defined $t;
        }

        if(defined(my $code = $set->{DYNAMIC}))
        {   my $t = $code->($tag, $attrs, $then, $else);
            push @values, $t if defined $t;
        }
    }

    @values;
}


sub pushValues($)
{   my ($self, $attrs) = @_;

    if(my $markers = $attrs->{markers})
    {   my @markers = ref $markers eq 'ARRAY' ? @$markers
         : map {s/\\\,//g; $_} split /(?!<\\)\,\s*/, $markers;

        push @markers, $markers[0] . '/'
            if @markers==2;

        push @markers, $markers[1]
            if @markers==3;

        $attrs->{markers}
          = [ map { ref $_ eq 'Regexp' ? $_ : qr/\Q$_/ } @markers ];
    }

    if(my $search = $attrs->{search})
    {   $attrs->{search} = [ split /\:/, $search ]
            if ref $search ne 'ARRAY';
    }

    $self->{values} = { %$attrs, NEXT => $self->{values} };
}


sub popValues()
{   my $self = shift;
    $self->{values} = $self->{values}{NEXT};
}


sub includeTemplate($$$)
{   my ($self, $tag, $attrs, $then, $else) = @_;

    defined $then || defined $else
        and die "ERROR: template is not a container";

    if(my $fn = $attrs->{file})
    {   return (scalar $self->processFile($fn, $attrs));
    }

    if(my $name = $attrs->{macro})
    {    my $macro = $self->{macros}{$name}
            or die "ERROR: cannot find macro $name";

        return $macro->($tag, $attrs, $then, $else);
    }

    my $source = $self->valueFor('source') || '??';
    die "ERROR: file or macro attribute required for template in $source\n";
}


sub loadFile($)
{   my ($self, $relfn) = @_;
    my $absfn;

    if(File::Spec->file_name_is_absolute($relfn))
    {   my $fn = File::Spec->canonpath($relfn);
        $absfn = $fn if -f $fn;
    }

    unless($absfn)
    {   my @srcs = map { @$_ } $self->allValuesFor('search');
        foreach my $dir (@srcs)
        {   $absfn = File::Spec->rel2abs($relfn, $dir);
            last if -f $absfn;
            $absfn = undef;
        }
    }

    unless(defined $absfn)
    {   my $source = $self->valueFor('source') || '??';
        die "ERROR: Cannot find template $relfn in $source\n";
    }

    my $in = IO::File->new($absfn, 'r');
    unless(defined $in)
    {   my $source = $self->valueFor('source') || '??';
        die "ERROR: Cannot read from $absfn in $source: $!";
    }

    \(join '', $in->getlines);  # auto-close in
}


sub parse($@)
{   my ($self, $template) = (shift, shift);
    $self->process(\$template, @_);
}


sub parseTemplate($)
{   my ($self, $template) = @_;

    my @frags;

    my $markers = $self->valueFor('markers');

    # Remove white-space escapes
    $template =~ s! \\ (?: \s* (?: \\ \s*)? \n)+
                    (?: \s* (?= $markers->[0] | $markers->[3] ))?
                  !!mgx;

    # NOT_$tag supported for backwards compat
    while( $template =~ s!^(.*?)        # text before container
                           $markers->[0] \s*
                           (?: IF \s* )?
                           (NOT (?:_|\s+) )?
                           (\w+) \s*    # tag
                           (.*?) \s*    # attributes
                           $markers->[1]
                         !!xs
         )
    {   push @frags, $1;
        my ($not, $tag, $attr) = ($2, $3, $4);
        my ($then, $else);

        if($template =~ s! (.*?)           # contained
                           ( $markers->[2]
                             \s* $tag \s*  # "our" tag
                             $markers->[3]
                           )
                         !!xs)
        {   $then       = $1;
            my $endline = $2;

            if($then =~ m/$markers->[0] \s* $tag\b /xs)
            {   # oops: container is terminated for a brother (nesting
                # is not possible). Correct for the greedyness.
                $template = $then.$endline.$template;
                $then     = undef;
            }
        }

        if($not) { ($then, $else) = (undef, $then) }
        elsif(!defined $then) { }
        elsif($then =~ s! $markers->[0]
                          \s* ELSE (?:_|\s+)
                          $tag \s*
                          $markers->[1]
                          (.*)
                        !!xs)
        {   # ELSE_$tag for backwards compat
            $else = $1;
        }

        push @frags, [$tag, $self->parseAttrs($attr), $then, $else];
    }

    push @frags, $template;
    \@frags;
}


sub parseAttrs($)
{   my ($self, $string) = @_;

    my %attrs;
    while( $string =~
        s/^\s*(\w+)                     # attribute name
           \s* (?: \=\>? \s*            # optional a value
                   ( \"[^"]*\"          # dquoted value
                   | \'[^']*\'          # squoted value
                   | \$\{ [^}]+ \}      # complex variable
                   | \$\w+              # simple variable
                   | [^\s,]+            # unquoted value
                   )
                )?
                \s* \,?                 # optionally separated by commas
          //xs)
    {   my ($k, $v) = ($1, $2);
        unless(defined $v)
        {  $attrs{$k} = 1;
           next;
        }

        if($v =~ m/^\'(.*)\'$/)
        {   # Single quoted parameter, no interpolation
            $attrs{$k} = $1;
            next;
        }

        $v =~ s/^\"(.*)\"$/$1/;
        my @v = split /( \$\{[^\}]+\} | \$\w+ )/x, $v;

        if(@v==1 && $v[0] !~ m/^\$/)
        {   $attrs{$k} = $v[0];
            next;
        }

        my @steps;
        foreach (@v)
        {   if( m/^ (?: \$(\w+) | \$\{ (\w+) \s* \} ) $/x )
            {   push @steps, [ $+ ];
            }
            elsif( m/^ \$\{ (\w+) \s* ([^\}]+? \s* ) \} $/x )
            {   push @steps, [ $1, $self->parseAttrs($2) ];
            }
            else
            {   push @steps, $_;
            }
        }

        $attrs{$k} = \@steps;
    }

    \%attrs;
}


1;