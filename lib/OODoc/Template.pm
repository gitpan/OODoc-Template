# Copyrights 2003,2007 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.00.
package OODoc::Template;
use vars '$VERSION';
$VERSION = '0.02';

use IO::File   ();


sub new(@)
{   my ($class, %args) = @_;
    (bless {}, $class)->init(\%args);
}

sub init($)
{   my ($self, $args) = @_;

    my $templ  = $args->{template} || sub { $self->includeTemplate($_[1]) };

    $self->pushValues
     ( template => $templ
     , search   => '.'
     );
    
    $self;
}


sub parse($@)
{   my ($self, $template) = (shift, shift);

    my $values = @_==1 ? shift : {@_};
    $values->{source} ||= 'parse()';
    $self->pushValues($values);

    while( $template =~ s|^(.*?)        # text before container
                           \<\!\-\-\{   # tag open
                           \s* (NOT_)?
                               (\w+)    # tag
                           \s* (.*?)    # attributes
                           \s* \}\-\-\> # tag open end
                         ||sx
         )
    {   print $1;
        my ($not, $tag, $attributes) = ($2, $3, $4);

        if($template =~ s| (.*?)             # something
                           ( \<\!\-\-\{      # tag close
                             \s* \/$tag      # "our" tag
                             \s* \}\-\-\>    # tag close end
                           )
                         ||sx
           )
        {   # found container
            my ($container, $endtag) = ($1, $2);

            if( $container =~ m/\<\!\-\-\{\s*$tag\b/ )
            {   # oops: container is terminated for a brother (nesting
                # is not permitted. Try to correct my greedyness.
                $template = $container.$endtag.$template;
                $self->handle($tag, $attributes, undef);
            }
            else
            {   # container is mine!
                $self->handle($tag, $attributes, $container);
            }
        }
        else
        {   # not a container
            $self->handle($tag, $attributes, undef);
        }
    }

    print $template;                    # remains
    $self->popValues;
}


sub parseFile($@)
{   my ($self, $filename) = (shift, shift);
    
    my $values = @_==1 ? shift : {@_};
    $values->{source} ||= 'parseFile()';

    $self->parse($self->loadTemplate($filename));
}


sub handle($;$$)
{   my ($self, $tag, $attributes, $container) = @_;
    defined $attributes or $attributes = '';
    defined $container  or $container  = '';

    my %attrs;
    while( $attributes =~
        s/^\s*(\w+)                     # attribute name
           \s* (?: \=\> \s*             # optional value
                   ( \"[^"]*\"          # dquoted value
                   | \'[^']*\'          # squoted value
                   | \$\{ [^}]* \}      # complex variable
                   | \$\w+              # simple variable
                   | \S+                # unquoted value
                   )
                )?
                \s* \,?                 # optionally separated by commas
          //xs)
    {  my ($k, $v) = ($1, $2);
       defined $v or $v = 1;

       if($v =~ m/^\'(.*)\'$/)
       {  # Single quoted parameter, no interpolation
          $v = $1;
       }
       elsif($v =~ m/^\"(.*)\"$/)
       {  # Double quoted parameter, with interpolation
          $v = $1;
          $v =~ s/\$\{(\w+)\s*(.*?)}|\$(\w+)/$self->handle($1, $2)/ge;
       }
       elsif($v =~ m/^\$\{(\w+)\s*(.*?)}$/)
       {  # complex variables
          $v = $self->handle($1, $2);
       }
       elsif($v =~ m/^\$(\w+)$/)
       {  # simple variables
          $v = $self->handle($1);
       }

       $attrs{$k} = $v;
    }

    my $value  = $self->valueFor($tag, \%attrs, \$container);
    return unless defined $value;       # ignore container

       if(!ref $value)           { print $value }
    elsif(ref $value eq 'HASH')  { $self->parse($container, $value) }
    elsif(ref $value eq 'ARRAY') { $self->parse($container, $_) for @$value }
    else { die "Huh? value for $tag is a ".ref($value)."\n" }
}


sub valueFor($$$)
{   my ($self, $tag, $attrs, $textref) = @_;

    for(my $set = $self->{values}; defined $set; $set = $set->{NEXT})
    {   
        if(defined(my $v = $set->{$tag}))
        {   # HASH  defines container
            # ARRAY defines container loop
            # object or other things can be stored as well, but may get
            # stringified.
            return ref $v eq 'CODE' ? $v->($tag, $attrs, $textref) : $v;
        }

        if(defined(my $code = $set->{DYNAMIC}))
        {   my $value = $code->($tag, $attrs, $textref);
            return $value if defined $value;
            # and continue the search otherwise
        }
    }

    undef;
}


sub allValuesFor($)
{   my ($self, $tag) = @_;
    my @values;

    for(my $set = $self->{values}; defined $set; $set = $set->{NEXT})
    {   
        if(defined(my $v = $set->{$tag}))
        {   my $t = ref $v eq 'CODE' ? $v->($tag, $attrs, $textref) : $v;
            push @values, $t if defined $t;
        }

        if(defined(my $code = $set->{DYNAMIC}))
        {   my $t = $code->($tag, $attrs, $textref);
            push @values, $t if defined $t;
        }
    }

    @values;
}


sub pushValues($)
{   my ($self, $attrs) = @_;
    $self->{values} = { %$attrs, NEXT => $self->{values} };
}


sub popValues()
{   my $self = shift;
    $self->{values} = $self->{values}{NEXT};
}


sub includeTemplate($)
{   my ($self, $attrs) = @_;
    my $values = $self->pushValues($attrs);

    my $fn = $self->valueFor('file');
    unless(defined $fn)
    {   my $source = $self->valueFor('source') || '??';
        die "ERROR: there is no filename found with template in $source\n";
    }

    $self->popValues;
}


sub loadTemplate($)
{   my ($self, $relfn) = @_;
    my $absfn;

    if(File::Spec->file_name_is_absolute($relfn))
    {   my $fn = File::Spec->canonpath($relfn);
        $absfn = $fn if -f $fn;
    }

    unless($absfn)
    {   my @srcs = map { ref $_ eq 'ARRAY' ? @$_ : split(':',$_) }
                      $self->allValuesFor('source');

        foreach my $dir (@srcs)
        {   my $fn = File::Spec->rel2abs($relfn, $dir);
            last if -f $fn;
        }
    }

    unless($absfn)
    {   my $source = $self->valueFor('source');
        die "ERROR: Cannot find template $relfn as mentioned in $source\n";
    }

    if(my $cached = $templ_cache{$absfn})
    {   my $mtime = $cached->[1]{mtime};
        return @$cached if -M $absfn==$mtime;
    }

    my $in = IO::File->new($absfn, 'r');
    unless(defined $in)
    {   my $source = $self->valueFor('source');
        die "ERROR: Cannot read from $absfn, named in $source\n";
    }

    join '', $in->getlines;  # auto-close in
}


1;
