package MusicBrainz::Server::Controller::Root;
use Moose;
BEGIN { extends 'Catalyst::Controller' }

# Import MusicBrainz libraries
use DBDefs;
use HTTP::Status qw( :constants );
use ModDefs;
use MusicBrainz::Server::Data::Utils qw( model_to_type );
use MusicBrainz::Server::Replication ':replication_type';

#
# Sets the actions in this controller to be registered with no prefix
# so they function identically to actions created in MyApp.pm
#
__PACKAGE__->config->{namespace} = '';

with 'MusicBrainz::Server::Controller::Role::Profile' => {
    threshold => DBDefs::PROFILE_SITE()
};

=head1 NAME

MusicBrainz::Server::Controller::Root - Root Controller for musicbrainz

=head1 DESCRIPTION

This controller handles application wide logic for the MusicBrainz website.

=head1 METHODS

=head2 index

Render the standard MusicBrainz welcome page, which is mainly static,
other than the blog feed.

=cut

sub index : Path Args(0)
{
    my ($self, $c) = @_;

    $c->stash->{template} = 'main/index.tt';
}

=head2 default

Handle any pages not matched by a specific controller path. In our case,
this means serving a 404 error page.

=cut

sub default : Path
{
    my ($self, $c) = @_;
    $c->detach('/error_404');
}

sub error_400 : Private
{
    my ($self, $c) = @_;

    $c->response->status(400);
    $c->stash->{template} = 'main/400.tt';
    $c->detach;
}

sub error_401 : Private
{
    my ($self, $c) = @_;

    $c->response->status(401);
    $c->stash->{template} = 'main/401.tt';
    $c->detach;
}

sub error_403 : Private
{
    my ($self, $c) = @_;

    $c->response->status(403);
    $c->stash->{template} = 'main/403.tt';
}

sub error_404 : Private
{
    my ($self, $c) = @_;

    $c->response->status(404);
    $c->stash->{template} = 'main/404.tt';
}

sub error_500 : Private
{
    my ($self, $c) = @_;

    $c->response->status(500);
    $c->stash->{template} = 'main/500.tt';
    $c->detach;
}

sub error_503 : Private
{
    my ($self, $c) = @_;

    $c->response->status(503);
    $c->stash->{template} = 'main/503.tt';
    $c->detach;
}

sub error_mirror : Private
{
    my ($self, $c) = @_;

    $c->response->status(403);
    $c->stash->{template} = 'main/mirror.tt';
    $c->detach;
}

sub error_mirror_404 : Private
{
    my ($self, $c) = @_;

    $c->response->status(404);
    $c->stash->{template} = 'main/mirror_404.tt';
    $c->detach;
}

sub js_text_strings : Path('/text.js') {
    my ($self, $c) = @_;
    $c->res->content_type('text/javascript');
    $c->stash->{template} = 'scripts/text_strings.tt';
}

sub js_unit_tests : Path('/unit_tests') {
    my ($self, $c) = @_;
    $c->stash->{template} = 'scripts/unit_tests.tt';
}

sub begin : Private
{
    my ($self, $c) = @_;

    return if exists $c->action->attributes->{Minimal};

    # if no javascript cookie is set we don't know if javascript is enabled or not.
    my $jscookie = $c->request->cookie('javascript');
    my $js = $jscookie ? $jscookie->value : "unknown";
    $c->response->cookies->{javascript} = { value => ($js eq "unknown" ? "false" : $js) };

    $c->stash(
        javascript => $js,
        no_javascript => $js eq "false",
        wiki_server => &DBDefs::WIKITRANS_SERVER,
        server_details => {
            staging_server => &DBDefs::DB_STAGING_SERVER,
            is_slave_db    => &DBDefs::REPLICATION_TYPE == RT_SLAVE,
        },
    );

    if ($c->req->user_agent && $c->req->user_agent =~ /MSIE/i) {
        $c->stash->{looks_like_ie} = 1;
        $c->stash->{needs_chrome} = !($c->req->user_agent =~ /chromeframe/i);
    }

    # Setup the searchs on the sidebar
    $c->form( sidebar_search => 'Search::Search' );

    # Returns a special 404 for areas of the site that shouldn't exist on a slave (e.g. /user pages)
    if (exists $c->action->attributes->{HiddenOnSlaves}) {
        $c->detach('/error_mirror_404') if ($c->stash->{server_details}->{is_slave_db});
    }

    # Anything that requires authentication isn't allowed on a mirror server (e.g. editing, registering)
    if (exists $c->action->attributes->{RequireAuth} || $c->action->attributes->{ForbiddenOnSlaves}) {
        $c->detach('/error_mirror') if ($c->stash->{server_details}->{is_slave_db});
    }

    # Can we automatically login?
    if (!$c->user_exists) {
        $c->forward('/user/cookie_login');
    }

    if (exists $c->action->attributes->{RequireAuth})
    {
        $c->forward('/user/do_login');
        my $privs = $c->action->attributes->{RequireAuth};
        if ($privs && ref($privs) eq "ARRAY") {
            foreach my $priv (@$privs) {
                last unless $priv;
                my $accessor = "is_$priv";
                if (!$c->user->$accessor) {
                    $c->detach('/error_403');
                }
            }
        }
    }

    if (exists $c->action->attributes->{Edit} && $c->user_exists)
    {
        $c->forward('/error_401') unless $c->user->has_confirmed_email_address;
    }

    if (exists $c->action->attributes->{Edit} && DBDefs::DB_READ_ONLY) {
        $c->stash( message => 'The server is currently in read only mode and is not accepting edits');
        $c->forward('/error_400');
    }

    # Load current relationship
    my $rel = $c->session->{current_relationship};
    if ($rel)
    {
    $c->stash->{current_relationship} = $c->model(ucfirst $rel->{type})->load($rel->{id});
    }

    # Update the tagger port
    if (exists $c->req->query_params->{tport})
    {
        $c->session->{tport} = $c->req->query_params->{tport};
    }

    # Merging
    if (my $merger = $c->session->{merger}) {
        my $model = $c->model($merger->type);
        my @merge = values %{
            $model->get_by_ids($merger->all_entities)
        };
        $c->model('ArtistCredit')->load(@merge);

        $c->stash(
            to_merge => [ @merge ],
            merger => $merger,
            merge_link => $c->uri_for_action(
                model_to_type($merger->type) . '/merge',
            )
        );
    }

    my $r = $c->model('RateLimiter')->check_rate_limit('frontend ip=' . $c->req->address);
    if ($r && $r->is_over_limit) {
        $c->response->status(HTTP_SERVICE_UNAVAILABLE);
        $c->res->content_type("text/plain; charset=utf-8");
        $c->res->headers->header(
            'X-Rate-Limited' => sprintf('%.1f %.1f %d', $r->rate, $r->limit, $r->period)
        );
        $c->stash->{template} = 'main/rate_limited.tt';
        $c->detach;
    }
}

=head2 end

Attempt to render a view, if needed. This will also set up some global variables in the
context containing important information about the server used on the majority of templates,
and also the current user.

=cut

sub end : ActionClass('RenderView')
{
    my ($self, $c) = @_;

    return if exists $c->action->attributes->{Minimal};

    $c->stash->{server_details} = {
        staging_server             => &DBDefs::DB_STAGING_SERVER,
        staging_server_description => &DBDefs::DB_STAGING_SERVER_DESCRIPTION,
        is_slave_db                => &DBDefs::REPLICATION_TYPE == RT_SLAVE,
        is_sanitized               => &DBDefs::DB_STAGING_SERVER_SANITIZED,
        developement_server        => &DBDefs::DEVELOPMENT_SERVER
    };

    # Determine which server version to display. If the DBDefs string is empty
    # attempt to display the current subversion revision
    if (&DBDefs::VERSION)
    {
        $c->stash->{server_details}->{version} = &DBDefs::VERSION;
    }

    # For displaying release attributes
    $c->stash->{release_attribute}        = \&MusicBrainz::Server::Release::attribute_name;
    $c->stash->{plural_release_attribute} = \&MusicBrainz::Server::Release::attribute_name_as_plural;

    # Working with quality levels
    $c->stash->{data_quality} = \&ModDefs::GetQualityText;

    # Displaying track lengths
    $c->stash->{track_length} =\&MusicBrainz::Server::Track::FormatTrackLength;

    $c->stash->{artist_type} = \&MusicBrainz::Server::Artist::type_name;
    $c->stash->{begin_date_name} = \&MusicBrainz::Server::Artist::begin_date_name;
    $c->stash->{end_date_name  } = \&MusicBrainz::Server::Artist::end_date_name;

    $c->stash->{vote} = \&ModDefs::vote_name;

    $c->stash->{release_format} = \&MusicBrainz::Server::ReleaseEvent::release_format_name;

    $c->stash->{various_artist_mbid} = ModDefs::VARTIST_MBID;

    $c->stash->{wiki_server} = &DBDefs::WIKITRANS_SERVER;

    if (!$c->debug && scalar @{ $c->error }) {
        $c->stash->{errors} = $c->error;
        for my $error ( @{ $c->error } ) {
            $c->log->error($error);
        }
        $c->stash->{template} = 'main/500.tt';
        $c->clear_errors;
    }
}

sub chrome_frame : Local
{
    my ($self, $c) = @_;
    $c->stash( template => 'main/frame.tt' );
}

=head1 LICENSE

This software is provided "as is", without warranty of any kind, express or
implied, including  but not limited  to the warranties of  merchantability,
fitness for a particular purpose and noninfringement. In no event shall the
authors or  copyright  holders be  liable for any claim,  damages or  other
liability, whether  in an  action of  contract, tort  or otherwise, arising
from,  out of  or in  connection with  the software or  the  use  or  other
dealings in the software.

GPL - The GNU General Public License    http://www.gnu.org/licenses/gpl.txt
Permits anyone the right to use and modify the software without limitations
as long as proper  credits are given  and the original  and modified source
code are included. Requires  that the final product, software derivate from
the original  source or any  software  utilizing a GPL  component, such  as
this, is also licensed under the GPL license.

=cut

1;
