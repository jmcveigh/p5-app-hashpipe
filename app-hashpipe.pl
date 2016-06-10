# hashpipe_cli.pl
# Twitter photograph hog
# download all JPEG media accessible by screen_name

use common::sense;

package MyRedditClient {
    use parent 'Reddit::Client';
    
    # this is the default for the time context parameter
    use constant T_DEFAULT => 'year';
    
    sub my_fetch_links {
        my ($self, %param) = @_;
        my $query  = {};
        
        my $subreddit = $param{subreddit} || '';
        my $view      = $param{view}      || $self->SUPER::VIEW_DEFAULT;
        
        # accept time context paramter or set to default        
        my $t = $param{t} || T_DEFAULT;

        # include time context parameter in query string
        $query->{t} = $t;
        
        $query->{before} = $param{before} if $param{before};
        $query->{after}  = $param{after}  if $param{after};
        if (exists $param{limit}) { $query->{limit} = $param{limit} || 500; }
        else { $query->{limit} = $self->SUPER::DEFAULT_LIMIT; }   
        
        # NOTE: line below causes 404 error on request so it is skipped
        # $subreddit = $self->SUPER::subreddit($subreddit);
        
        my $args = [$view];
        unshift @$args, $subreddit if $subreddit;
        
        my $result = $self->SUPER::api_json_request(
            api      => ($subreddit ? $self->SUPER::API_LINKS_FRONT : $self->SUPER::API_LINKS_OTHER),
            args     => $args,
            data     => $query,
        );
        
        return [
            map {Reddit::Client::Link->new($self, $_->{data})} @{$result->{data}{children}} 
        ];
    }
}

package Archive {
    use Moose;
    with 'MooseX::Role::Tempdir';
    use Archive::Zip;
    use namespace::autoclean;
    
    has 'zip' => (
        is => 'ro',
        isa => 'Archive::Zip',
        required => 1,
        default => sub {  Archive::Zip->new },
    );
    
    __PACKAGE__->meta->make_immutable;
}

package HashPipe_CLI {
    use common::sense;
    
    use MooseX::App::Simple qw(Color);
    use File::Basename;
    use Net::Twitter::Lite::WithAPIv1_1;
    use Reddit::Client;
    use LWP::Simple;
    use Archive::Zip;
    use Term::ProgressBar::Simple;
    use List::Flatten;
    
    use feature 'say';
    
    option 'archive' => (
        is => 'rw',
        isa => 'Str',
        required => 1,
        documentation => 'This is the filename of the .zip archive which will contain the hogged photos.',
    );
    
    option 'subfolder' => (
        is => 'rw',
        isa => 'Str',
        documentation => 'This is the subfolder within the .zip archive which will contain the hogged photos.',
    );
    
    option 'prefix' => (
        is => 'rw',
        isa => 'Str',
        documentation => 'This is the prefix for the photo filenames within the .zip archive.',
    );

    option 'limit' => (
        is => 'rw',
        isa => 'Int',
        documentation => 'This is the maximum number of photos to hog.'
    );
    
    option 'screen-name' => (
        is => 'rw',
        isa => 'Str',
        documentation => 'This is the screen name of the Twitter account for which to hog photos.',
    );
    
    option 'subreddit' => (
        is => 'rw',
        isa => 'Str',
        documentation => 'This is the subreddit for which to hog photos',
    );
    
    has '_twttr' => (
        is => 'rw',
        isa => 'Net::Twitter::Lite',
    );
    
    has '_reddit' => (
        is => 'rw',
        isa => 'MyRedditClient',
    );
    
    has '_archive' => (
        is => 'rw',
        isa => 'Archive',
        default => sub  { Archive->new },
    );
    
    sub _ensure_options {
        # just make sure the options are sane
        my ($self) = @_;
        my ($screen_name, $subreddit, $outfile) = ($self->{'screen-name'}, $self->{'subreddit'}, $self->archive);
        
        if ($self->{'screen-name'}) {
            die "The Twitter screen name must contain only valid word characters." unless $screen_name =~ m/^([\w\-\.]+)$/;
        }
        
        if ($self->{'subreddit'}) {
            die "The subreddit must contain only valid word characters." unless $subreddit =~ m/^([\w\-\.]+)$/;
        }
        
        if (!$self->{'screen-name'} && !$self->{'subreddit'}) {
            die 'One of the following streams of photos must be specified : [--screen-name, --subreddit]'
        }
        
        my ($outfile_name,$outfile_path) = (basename($self->archive), dirname($self->archive));
        
        die "The photo archive must be in a path to which you can write." unless -w $outfile_path;
        die "The photo archive must be a .zip file." unless $outfile_name =~ m/^([\w\-\.]+)(\.zip)$/;

    }

    sub _get_twttr_timeline {
        my ($self) = @_;
        my $users = $self->_twttr->lookup_users({ screen_name => $self->{'screen-name'} });

        my @updates;
        
        my $oldest;
        my $responses;       
        
        # no 0.
        $responses = $self->_twttr->user_timeline({ exclude_replies => 1, user_id => $users->[-1]->{id},count => 200});    
        for (@{$responses}) {
            push @updates, $_;
            
        }
        
        $oldest = $updates[-1]->{id};
        
        for (1..15) {
            $responses = $self->_twttr->user_timeline({ exclude_replies => 1, user_id => $users->[-1]->{id},count => 200, max_id => $oldest});
            last unless $responses;
            
            my $new_oldest = $responses->[-1]->{id};
            last if $new_oldest == $oldest;
            $oldest = $new_oldest;
            
            for (@{$responses}) {
                push @updates, $_;
            }
        }
        
        return(\@updates);
    }
    
    sub _twttr_get_media {
        my ($self) = @_;
        my $updates = $self->_get_twttr_timeline;
        my @media_elements = flat map({ $_->{entities}->{media} if $_->{entities}->{media} } @{$updates});
        my @media = map({ $_->{media_url} if $_->{media_url} } @media_elements);
        
        return(\@media);
    }

    sub _reddit_get_media {
        my ($self) = @_;
        my @media;
        my @names;
        my $after;
        
        # this is the first iteration of the fetch_links loop
        # fetch 100 links
        my $posts = $self->_reddit->my_fetch_links(subreddit => $self->{'subreddit'}, limit => 100, view => Reddit::Client::VIEW_TOP, t => 'year');
        for (@{$posts}) {
            # push imgur urls
            if ($_->{url} =~ m/i\.imgur\.com/) {
                push @media, $_->{url};
                push @names, $_->{name};
            }
        }
        
        # next fetch_links will fetch all links after our last item
        $after = $names[-1];
        
        # contine to fetch links until no more are available
        while ($#{$posts} >= 1) {
            # fetch 100 links
            $posts = $self->_reddit->my_fetch_links(subreddit => $self->{'subreddit'}, limit => 100, view => Reddit::Client::VIEW_TOP, after => $after, t => 'year');
            my $new_after;
            
            try {
                
                # next fetch_links will fetch all links after our last item
                $new_after = $posts->[-1]->{name};
                last if $new_after eq $after;
                $after = $new_after;
                
                # push imgur urls
                for (@{$posts}) {
                    if ($_->{url} =~ m/i\.imgur\.com/) {
                        push @media, $_->{url};
                    }
                }
                
            } catch {
                # No safe test for the last url known by me, so we'll exit the loop on exception
                last;
            };
        }      
        
        return(\@media);
    }
    
    sub run {
        my ($self) = @_;
        
        $self->_ensure_options;
        $self->_connect_to_twttr if $self->{'screen-name'};
        $self->_connect_to_reddit if $self->{'subreddit'};

        my (@media,@media_twttr,@media_reddit);
        
        @media_twttr = @{$self->_twttr_get_media} if ($self->{'screen-name'});
        @media_reddit = @{$self->_reddit_get_media} if ($self->{'subreddit'});
        
        @media_twttr = splice(@media_twttr,0,$self->{'limit'}) if ($self->{'screen-name'} && $self->{'limit'});
        @media_reddit = splice(@media_reddit,0,$self->{'limit'}) if ($self->{'subreddit'} && $self->{'limit'});
        
        push @media, @media_twttr;
        push @media, @media_reddit;
        
        my $media_count = scalar @media;
        my $progress = Term::ProgressBar::Simple->new($media_count);
        my $idx = 0;
        
        for (@media) {
            my $media_url;
            my $ext = '';
            
            next unless $_;
            if(m/i\.imgur/) {
                m/(\w+)\.(\w+)$/;                
                my $tag = $1;
                
                next unless $tag;
                
                # watch for GIFV which is really a web document for a player
                $ext = $2;
                $media_url = "http://imgur.com/download/${tag}";                
            } else {
                m/\.(\w+)$/;
                $ext = $1;
                $media_url = $_;
            }
            
            # download photograph from twitter
            my $buf = get($media_url);
            
            if ($buf) {
                my $tmp_photo_outfile_basename;
                
                if ($self->{'prefix'}) {
                    $tmp_photo_outfile_basename = $self->{'prefix'} . '-' . sprintf("%04d.%s", $idx, $ext);
                } else {
                    $tmp_photo_outfile_basename = sprintf("%04d.%s", $idx, $ext);
                }
                
                my $tmp_photo_outfile = $self->_archive->tmpdir() . '\\' . $tmp_photo_outfile_basename;

                # write photograph to tmpdir with twitter defined filename
                open OUTFILE, '>', $tmp_photo_outfile or die 'Error writing Twitter photograph to disk in the temporary folder.';
                binmode OUTFILE;
                print OUTFILE $buf;
                close OUTFILE;
                
                # add photograph to archive
                if ($self->{'subfolder'}) {
                    $self->_archive->zip->addFile($tmp_photo_outfile,$self->{'subfolder'} . "\\" . $tmp_photo_outfile_basename);
                } else {
                    $self->_archive->zip->addFile($tmp_photo_outfile,$tmp_photo_outfile_basename);
                }
                
                $idx++;
            }

            $progress++;
        }
        
        unless($self->_archive->zip->writeToFileNamed($self->archive) == Archive::Zip::AZ_OK) {
            die 'An error occurred while writing archive to disk.'
        }
    }
}

require '.\auth-hashpipe.pm';

my $app_cmd = HashPipe_CLI->new_with_options->run unless caller;

1;