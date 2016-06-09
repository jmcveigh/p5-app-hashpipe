# hashpipe_cli.pl
# Twitter photograph hog
# download all JPEG media accessible by screen_name

use common::sense;

package Archive {
    use Moose;
    # with 'MooseX::Role::Tempdir';
    use Archive::Tar;
    use namespace::autoclean;
    
    has '_tar' => (
        is => 'ro',
        isa => 'Archive::Tar',
        required => 1,
        default => sub { Archive::Tar->new },
        # handles => [qw(add_files add_data write)],
        handles => [qw(add_files add_data write)],
    );
    
    __PACKAGE__->meta->make_immutable;
}

package HashPipe_CLI {
    use common::sense;
    
    use MooseX::App::Simple qw(Color);
    use File::Basename;
    use Net::Twitter::Lite::WithAPIv1_1;
    use LWP::Simple;
    use Archive::Tar;
    use Term::ProgressBar::Simple;
    use List::Flatten;
    
    use feature 'say';
    
    option 'archive' => (
        is => 'rw',
        isa => 'Str',
        required => 1,
        documentation => 'This is the filename of the .tar.gz archive which will contain the photos hogged from Twitter.',
    );
    
    option 'screen-name' => (
        is => 'rw',
        isa => 'Str',
        required => 1,
        documentation => 'This is the screen name of the Twitter account for which to hog photos.',
    );
    
    has '_twttr' => (
        is => 'rw',
        isa => 'Net::Twitter::Lite',
    );
    
    has '_tar' => (
        is => 'rw',
        isa => 'Archive',
    );
    
    sub ensure_options {
        # just make sure the options are sane
        my ($self) = @_;
        my ($screen_name, $outfile) = ($self->{'screen-name'}, $self->archive);
        
        die "The Twitter screen name must contain only valid word characters." unless $screen_name =~ m/^([\w\-\.]+)$/;
        my ($outfile_name,$outfile_path) = (basename($self->archive), dirname($self->archive));
        
        die "The Twitter archive must be in a path to which you can write." unless -w $outfile_path;
        die "The Twitter archive must be a .tar.gz file." unless $outfile_name =~ m/^([\w\-\.]+)(\.tar\.gz)$/;
    }

    sub connect_to_twttr {
        my ($self) = @_;
        # screen name jason_mcveigh for app
        $self->_twttr(Net::Twitter::Lite::WithAPIv1_1->new(
            consumer_key => 'haUdBgll2xvgqY27ZPGQSQ0Ff',
            consumer_secret => 'VbvgvOowMBw81Q1BEZwlenpmVHNmaUfI56UwrolfZgYcnpb2c9',
            access_token_secret => 'Px0QfBzAoLDXvYTymeA7Mes1dEM8hqIfpttjmHYecyJqi',
            access_token => '2893782597-FC3GweNHjyal0wv4yhiUd1rpYx1Mt0Ztb6MMA4X',
            ssl => 1,
            
        )) or die 'This Twitter App could not connect.';
    }
    
    sub get_user_timeline {
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
        print '.';
        
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
            
            print '.';            
        }
        
        say '';
        
        return(\@updates);
    }

    sub run {
        my ($self) = @_;
        $self->ensure_options;
        $self->connect_to_twttr;
        $self->_tar(Archive->new);
        my $updates = $self->get_user_timeline;
        my @media_elements = flat map({ $_->{entities}->{media} if $_->{entities}->{media} } @{$updates});
        my @media = map({ $_->{media_url} if $_->{media_url} } @media_elements);
        my $media_count = scalar @media;
        my $progress = Term::ProgressBar::Simple->new($media_count);
        my $idx = 0;
        for (@media) {
            # download photograph from twitter
            my $buf = get($_);
            
            if ($buf) {
                
                my $tmp_photo_outfile_basename = $self->{'screen-name'} . '-' . sprintf("%04d.jpg", $idx);
                #my $tmp_photo_outfile = $self->_tar->tmpdir() . '\\' . $tmp_photo_outfile_basename;

                # write photograph to tmpdir with twitter defined filename
                # open OUTFILE, '>', $tmp_photo_outfile or die 'Error writing Twitter photograph to disk in the temporary folder.';
                # binmode OUTFILE;
                # print OUTFILE $buf;
                # close OUTFILE;
                
                # add photograph to archive
                # $self->_tar->add_files(($tmp_photo_outfile));
                
                $self->_tar->add_data($tmp_photo_outfile_basename, $buf, { name => $tmp_photo_outfile_basename, prefix => $self->{'screen-name'} });
                
                $idx++;
            }
            $progress++;
        }
    
        # write .tar.gz archive to disk
        $self->_tar->write($self->archive, COMPRESS_GZIP);
        say "success, see " . $self->archive;
    }
}

my $app_cmd = HashPipe_CLI->new_with_options->run unless caller;

1;