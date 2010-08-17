package MusicBrainz::Server::Controller::WS::1::Tag;
use Moose;
BEGIN { extends 'MusicBrainz::Server::Controller' }

use aliased 'MusicBrainz::Server::WebService::XMLSerializerV1';
use aliased 'MusicBrainz::Server::WebService::Serializer::XML::1::List';

use MusicBrainz::Server::Data::Utils qw( type_to_model );

has 'serializer' => (
    is => 'ro',
    default => sub { XMLSerializerV1->new }
);

sub tag : Path('/ws/1/tag')
{
    my ($self, $c) = @_;
    $c->authenticate({}, 'webservice');

    if ($c->req->method eq 'POST') {
        if (exists $c->req->params->{entity}) {
            # Looks like a single entity tag submission
            my ($id, $type, $tags) = (
                map {
                    $c->req->params->{$_}
                } qw( id entity tags )
            );

            my $model = $c->model( type_to_model($type) );
            my $entity = $model->get_by_gid($id);

            $model->tags->update($c->user->id, $entity->id, $tags);
        }
        else {
            my @batch;

            for(my $count = 0;; $count++) {
		my $entity = $c->req->params->{"entity.$count"};
		my $id = $c->req->params->{"id.$count"};
		my $tags = $c->req->params->{"tags.$count"};

		last if (!$entity || !$id || !$tags) || @batch >= 20;

		push @batch, { entity => $entity, id => $id, tags => $tags };
            }

            for my $submission (@batch) {
                my $model = $c->model(type_to_model($submission->{entity}));
                my $entity = $model->get_by_gid($submission->{id});
                $model->tags->update($c->user->id, $entity->id, $submission->{tags});
            }
        }

        $c->res->content_type($self->serializer->mime_type . '; charset=utf-8');
        $c->res->body($self->serializer->xml( '' ));
    }
    else {
        my ($id, $type) = ($c->req->query_params->{id}, $c->req->query_params->{entity});

        my $model = $c->model( type_to_model($type) );
        my $entity = $model->get_by_gid($id);
        my @tags = $model->tags->find_user_tags($c->user->id, $entity->id);

        $c->res->content_type($self->serializer->mime_type . '; charset=utf-8');
        $c->res->body($self->serializer->xml( List->new->serialize([ map { $_->tag } @tags ]) ));
    }
}

__PACKAGE__->meta->make_immutable;
1;


