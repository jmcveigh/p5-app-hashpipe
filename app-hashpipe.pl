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
    use File::Path qw(remove_tree);   
    use namespace::autoclean;    
    
    has 'zip' => (
        is => 'ro',
        isa => 'Archive::Zip',
        required => 1,
        default => sub {  Archive::Zip->new },
    );
    
    sub remove_tmpdir {
        my ($self) = @_;
        remove_tree($self->tmpdir, { safe => 1 }) if (-e $self->tmpdir);
    }
    
    __PACKAGE__->meta->make_immutable;
}

package HashPipe_CLI {
    use common::sense;
    
    use MooseX::App::Simple qw(Color);
    
    use Data::Dumper;
    
    use List::Flatten;    
    use File::Basename;
    use LWP::Simple;
    
    use Archive::Zip;
    
    use Net::Twitter::Lite::WithAPIv1_1;    
    use Reddit::Client;
    use Flickr::API;
    use API::Instagram;
    
    use Term::ProgressBar::Simple;
    
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
        documentation => 'This is the subreddit for which to hog photos.',
    );
    
    option 'yahoo-id' => (
        is => 'rw',
        isa => 'Str',
        documentation => 'This is the Flickr Yahoo ID for which to hog photos.'
    );

    option 'instagram-user' => (
        is => 'rw',
        isa => 'Str',
        documentation => 'This is the Instagram User for which to hog photos.'
    );
    
    has '_twttr' => (
        is => 'rw',
        isa => 'Net::Twitter::Lite',
    );
    
    has '_reddit' => (
        is => 'rw',
        isa => 'MyRedditClient',
    );
    
    has '_flickr' => (
        is => 'rw',
        isa => 'Flickr::API',
    );
    
    has '_instagram' => (
        is => 'rw',
        isa => 'API::Instagram',
    );
    
    has '_archive' => (
        is => 'rw',
        isa => 'Archive',
        default => sub  { Archive->new },
    );
    
    sub _ensure_options {
        # just make sure the options are sane
        my ($self) = @_;
        my ($screen_name, $subreddit, $yahoo_id, $instagram_user, $outfile) = ($self->{'screen-name'}, $self->{'subreddit'}, $self->{'yahoo-id'}, $self->{'instagram-user'}, $self->archive);
        
        if ($self->{'screen-name'}) {
            die "The Twitter screen name must contain only valid word characters." unless $screen_name =~ m/^([\w\-\.]+)$/;
        }
        
        if ($self->{'subreddit'}) {
            die "The subreddit must contain only valid word characters." unless $subreddit =~ m/^([\w\-\.]+)$/;
        }
        
        if ($self->{'yahoo-id'}) {
            die "The yahoo-id must contain only valid word characters and spaces." unless $yahoo_id =~ m/^([\w\-\. ]+)$/;
        }
        
        if ($self->{'instagram-user'}) {            
            die "The instagram-user must contain only valid waord characters." unless $instagram_user =~ m/^([\w\-\. ]+)$/;            
            die "This Instagram app is pending approval.  For now, the only valid instagram user is the administrator 'jwmcveigh'" unless $instagram_user eq 'jwmcveigh';
        }
        
        if (!$self->{'screen-name'} && !$self->{'subreddit'} && !$self->{'yahoo-id'} && !$self->{'instagram-user'}) {
            die 'One of the following streams of photos must be specified : [--screen-name, --subreddit, --yahoo-id, --instagram-user]';
        }
        
        my ($outfile_name,$outfile_path) = (basename($self->archive), dirname($self->archive));
        
        die "The photo archive must be in a path to which you can write." unless -w $outfile_path;
        die "The photo archive must be a .zip file." unless $outfile_name =~ m/^([\w\-\.]+)(\.zip)$/;
    }
    
    sub _instagram_get_media {
        my ($self) = @_;
        my @media;
        my @ids;
        my $medias;
        my $search1 = $self->_instagram->search('user');
        my $users = $search1->find( q => $self->{'instagram-user'});
        
        for (@{$users}) {            
            
            $medias = $_->recent_medias(count => 10);
            for (@{$medias}) {
                my $media_url = (split(/\?/, $_->{'images'}->{'standard_resolution'}->{'url'}))[0];
                push @media, $media_url;
                push @ids, $_->{'id'};
            }
            
            my $max_id = $ids[-1];
            
            while (1) {
                $medias = $_->recent_medias(count => 10, max_id => $max_id);
                last unless ref($medias) eq 'ARRAY';
                for (@{$medias}) {
                    my $media_url = (split(/\?/, $_->{'images'}->{'standard_resolution'}->{'url'}))[0];
                    say $media_url;
                    push @media, $media_url;
                    push @ids, $_->{'id'};
                }
                my $new_max_id = $ids[-1];
                last if ($max_id eq $new_max_id);
                $max_id = $new_max_id;
            }
        }
        
        return(\@media);
    }
    
    sub _get_flickr_nsid {
        my ($self) = @_;
        my $response = $self->_flickr->execute_method('flickr.people.findByUsername', { username => $self->{'yahoo-id'} });
        if($response->{'success'}) {
            return($response->{'hash'}->{'user'}->{'nsid'});
        } else {
            return(0);
        }
    }

    sub _flickr_get_media {
        my ($self) = @_;
        my $user_id = $self->_get_flickr_nsid;
        if ($user_id) {
            my @media;
            my $page = 1;
            my $photos;
            
            # this is the first iteration of the fetch_links loop
            # fetch 100 links
            my $r1 = $self->_flickr->execute_method('flickr.people.getPhotos', { user_id => $user_id, content_type => 4, per_page => 50, page => $page });
            if($r1->{'success'}) {
                $photos = $r1->{'hash'}->{'photos'}->{'photo'};
                if ($photos && ref($photos) eq 'ARRAY') {
                    for (@{$photos}) {
                        my $r2 = $self->_flickr->execute_method('flickr.photos.getInfo', { photo_id => $_->{'id'}, secret => $_->{'secret'}});
                        if ($r2->{'success'}) {
                            my $farm_id = $r2->{'hash'}->{'photo'}->{'farm'};
                            my $server_id = $r2->{'hash'}->{'photo'}->{'server'};
                            my $photo_id = $r2->{'hash'}->{'photo'}->{'id'};
                            my $secret = $r2->{'hash'}->{'photo'}->{'secret'};
                            
                            my $media_url = "http://farm${farm_id}.static.flickr.com/${server_id}/${photo_id}_${secret}.jpg";
                            push @media, $media_url
                        }
                    }
                } elsif ($photos && ref($photos) eq 'HASH') {
                    my $r2 = $self->_flickr->execute_method('flickr.photos.getInfo', { photo_id => $photos->{'id'}, secret => $photos->{'secret'}});
                    if ($r2->{'success'}) {
                        my $farm_id = $r2->{'hash'}->{'photo'}->{'farm'};
                        my $server_id = $r2->{'hash'}->{'photo'}->{'server'};
                        my $photo_id = $r2->{'hash'}->{'photo'}->{'id'};
                        my $secret = $r2->{'hash'}->{'photo'}->{'secret'};
                        
                        my $media_url = "http://farm${farm_id}.static.flickr.com/${server_id}/${photo_id}_${secret}.jpg";
                        push @media, $media_url
                    }
                }
            }
            
            $page++;

            # fetch 100 links
            while (1) {
                my $r3 = $self->_flickr->execute_method('flickr.people.getPhotos', { user_id => $user_id, content_type => 4, per_page => 50, page => $page });
                if($r3->{'success'}) {
                    $photos = $r3->{'hash'}->{'photos'}->{'photo'};
                    if ($photos && ref($photos) eq 'ARRAY') {
                        for (@{$photos}) {
                            my $r4 = $self->_flickr->execute_method('flickr.photos.getInfo', { photo_id => $_->{'id'}, secret => $_->{'secret'}});
                            if ($r4->{'success'}) {
                                my $farm_id = $r4->{'hash'}->{'photo'}->{'farm'};
                                my $server_id = $r4->{'hash'}->{'photo'}->{'server'};
                                my $photo_id = $r4->{'hash'}->{'photo'}->{'id'};
                                my $secret = $r4->{'hash'}->{'photo'}->{'secret'};
                                
                                my $media_url = "http://farm${farm_id}.static.flickr.com/${server_id}/${photo_id}_${secret}.jpg";
                                push @media, $media_url
                            }
                        }
                    } else {
                        last;
                    }
                } else {
                    last;
                }
                
                $page++;
            }
            
            return(\@media);        
        }
        return([]);        
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
        
        # validate commandline options
        $self->_ensure_options;
        
        # connect to appropriate networks
        $self->_connect_to_instagram if ($self->{'instagram-user'});
        $self->_connect_to_flickr if ($self->{'yahoo-id'});
        $self->_connect_to_twttr if ($self->{'screen-name'});
        $self->_connect_to_reddit if ($self->{'subreddit'});

        # collect urls for media for which to download
        my (@media,@media_twttr,@media_reddit,@media_flickr, @media_instagram);
        
        @media_instagram = @{$self->_instagram_get_media} if ($self->{'instagram-user'});
        @media_flickr = @{$self->_flickr_get_media} if ($self->{'yahoo-id'});
        @media_twttr = @{$self->_twttr_get_media} if ($self->{'screen-name'});
        @media_reddit = @{$self->_reddit_get_media} if ($self->{'subreddit'});
        
        # apply limit to each network's list of urls for media
        if ($self->{'limit'}) {
            @media_instagram = splice(@media_instagram,0,$self->{'limit'}) if ($self->{'instagram-user'});
            @media_flickr = splice(@media_flickr,0,$self->{'limit'}) if ($self->{'yahoo-id'});
            @media_twttr = splice(@media_twttr,0,$self->{'limit'}) if ($self->{'screen-name'});
            @media_reddit = splice(@media_reddit,0,$self->{'limit'}) if ($self->{'subreddit'});
        }
        
        # create master list of media to download
        push @media, @media_instagram;
        push @media, @media_flickr;
        push @media, @media_twttr;
        push @media, @media_reddit;
        
        my $media_count = scalar @media;
        my $progress = Term::ProgressBar::Simple->new($media_count);
        my $idx = 0;
        
        # download media
        for (@media) {
            my $media_url;
            my $ext = '';
            
            next unless $_;
            
            if(m/i\.imgur/) {
                # special case for imgur
                m/(\w+)\.(\w+)$/;                
                my $tag = $1;
                
                next unless $tag;
                
                $ext = $2;
                $media_url = "http://imgur.com/download/${tag}";                
            } else {
                # run-of-the-mill media download
                m/\.(\w+)$/;
                $ext = $1;
                $media_url = $_;
            }
            
            # download photograph from media network
            my $buf = get($media_url);
            
            if ($buf) {
                my $tmp_photo_outfile_basename;
                
                # decide on filename
                if ($self->{'prefix'}) {
                    $tmp_photo_outfile_basename = $self->{'prefix'} . '-' . sprintf("%04d.%s", $idx, $ext);
                } else {
                    $tmp_photo_outfile_basename = sprintf("%04d.%s", $idx, $ext);
                }
                
                # decide on storage location                
                my $tmp_photo_outfile = $self->_archive->tmpdir() . '\\' . $tmp_photo_outfile_basename;

                # write media to tmpdir
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
        
        $self->_archive->remove_tmpdir;
    }
}

require '.\auth-hashpipe.pm';

my $app_cmd = HashPipe_CLI->new_with_options->run unless caller;

1;