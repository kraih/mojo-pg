package Mojo::Pg::Database;
use Mojo::Base 'Mojo::EventEmitter';

use Carp qw(croak shortmess);
use DBD::Pg ':async';
use Mojo::IOLoop;
use Mojo::JSON 'to_json';
use Mojo::Pg::Results;
use Mojo::Pg::Transaction;
use Mojo::Util 'monkey_patch';
use Scalar::Util 'weaken';

has [qw(dbh pg)];
has results_class => 'Mojo::Pg::Results';

for my $name (qw(delete insert select update)) {
  monkey_patch __PACKAGE__, $name, sub {
    my ($self, @cb) = (shift, ref $_[-1] eq 'CODE' ? pop : ());
    return $self->query($self->pg->abstract->$name(@_), @cb);
  };
}

sub DESTROY {
  my $self = shift;

  my $waiting = $self->{waiting};
  $waiting->{cb}($self, 'Premature connection close', undef) if $waiting->{cb};

  return unless (my $pg = $self->pg) && (my $dbh = $self->dbh);
  $pg->_enqueue($dbh) unless $dbh->{private_mojo_no_reuse};
}

sub begin {
  my ($self, $level) = @_;
  my $tx = Mojo::Pg::Transaction->new(db => $self, level => $level);
  weaken $tx->{db};
  return $tx;
}

sub disconnect {
  my $self = shift;
  $self->_unwatch;
  $self->dbh->disconnect;
}

sub dollar_only { ++$_[0]{dollar_only} and return $_[0] }

sub is_listening { !!keys %{shift->{listen} || {}} }

sub listen {
  my ($self, $name) = @_;

  my $dbh = $self->dbh;
  $dbh->do('listen ' . $dbh->quote_identifier($name))
    unless $self->{listen}{$name}++;
  $self->_watch;

  return $self;
}

sub notify {
  my ($self, $name, $payload) = @_;

  my $dbh    = $self->dbh;
  my $notify = 'notify ' . $dbh->quote_identifier($name);
  $notify .= ', ' . $dbh->quote($payload) if defined $payload;
  $dbh->do($notify);
  $self->_notifications;

  return $self;
}

sub pid { shift->dbh->{pg_pid} }

sub ping { shift->dbh->ping }

sub query {
  my ($self, $query) = (shift, shift);
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;

  croak 'Non-blocking query already in progress' if $self->{waiting};

  my %attrs;
  $attrs{pg_placeholder_dollaronly} = 1        if delete $self->{dollar_only};
  $attrs{pg_async}                  = PG_ASYNC if $cb;
  my $sth = $self->dbh->prepare_cached($query, \%attrs, 3);
  local $sth->{HandleError} = sub { $_[0] = shortmess $_[0]; 0 };

  for (my $i = 0; $#_ >= $i; $i++) {
    my ($param, $attrs) = ($_[$i], {});
    if (ref $param eq 'HASH') {
      if (exists $param->{json}) { $param = to_json $param->{json} }
      elsif (exists $param->{type} && exists $param->{value}) {
        ($attrs->{pg_type}, $param) = @{$param}{qw(type value)};
      }
    }
    $sth->bind_param($i + 1, $param, $attrs);
  }
  $sth->execute;

  # Blocking
  unless ($cb) {
    $self->_notifications;
    return $self->results_class->new(sth => $sth);
  }

  # Non-blocking
  $self->{waiting} = {cb => $cb, sth => $sth};
  $self->_watch;
}

sub tables {
  my @tables = shift->dbh->tables('', '', '', '');
  return [grep { $_ !~ /^(?:pg_catalog|information_schema)\./ } @tables];
}

sub unlisten {
  my ($self, $name) = @_;

  my $dbh = $self->dbh;
  $dbh->do('unlisten ' . $dbh->quote_identifier($name));
  $name eq '*' ? delete $self->{listen} : delete $self->{listen}{$name};
  $self->_unwatch unless $self->{waiting} || $self->is_listening;

  return $self;
}

sub _notifications {
  my $self = shift;
  my $dbh  = $self->dbh;
  while (my $n = $dbh->pg_notifies) { $self->emit(notification => @$n) }
}

sub _unwatch {
  my $self = shift;
  return unless delete $self->{watching};
  Mojo::IOLoop->singleton->reactor->remove($self->{handle});
  $self->emit('close') if $self->is_listening;
}

sub _watch {
  my $self = shift;

  return if $self->{watching} || $self->{watching}++;

  my $dbh = $self->dbh;
  unless ($self->{handle}) {
    open $self->{handle}, '<&', $dbh->{pg_socket} or die "Can't dup: $!";
  }
  Mojo::IOLoop->singleton->reactor->io(
    $self->{handle} => sub {
      my $reactor = shift;

      $self->_unwatch if !eval { $self->_notifications; 1 };
      return unless $self->{waiting} && $dbh->pg_ready;
      my ($sth, $cb) = @{delete $self->{waiting}}{qw(sth cb)};

      # Do not raise exceptions inside the event loop
      my $result = do { local $dbh->{RaiseError} = 0; $dbh->pg_result };
      my $err = defined $result ? undef : $dbh->errstr;

      $self->$cb($err, $self->results_class->new(sth => $sth));
      $self->_unwatch unless $self->{waiting} || $self->is_listening;
    }
  )->watch($self->{handle}, 1, 0);
}

1;

=encoding utf8

=head1 NAME

Mojo::Pg::Database - Database

=head1 SYNOPSIS

  use Mojo::Pg::Database;

  my $db = Mojo::Pg::Database->new(pg => $pg, dbh => $dbh);
  $db->query('select * from foo')
    ->hashes->map(sub { $_->{bar} })->join("\n")->say;

=head1 DESCRIPTION

L<Mojo::Pg::Database> is a container for L<DBD::Pg> database handles used by
L<Mojo::Pg>.

=head1 EVENTS

L<Mojo::Pg::Database> inherits all events from L<Mojo::EventEmitter> and can
emit the following new ones.

=head2 close

  $db->on(close => sub {
    my $db = shift;
    ...
  });

Emitted when the database connection gets closed while waiting for
notifications.

=head2 notification

  $db->on(notification => sub {
    my ($db, $name, $pid, $payload) = @_;
    ...
  });

Emitted when a notification has been received.

=head1 ATTRIBUTES

L<Mojo::Pg::Database> implements the following attributes.

=head2 dbh

  my $dbh = $db->dbh;
  $db     = $db->dbh($dbh);

L<DBD::Pg> database handle used for all queries.

  # Use DBI utility methods
  my $quoted = $db->dbh->quote_identifier('foo.bar');

=head2 pg

  my $pg = $db->pg;
  $db    = $db->pg(Mojo::Pg->new);

L<Mojo::Pg> object this database belongs to.

=head2 results_class

  my $class = $db->results_class;
  $db       = $db->results_class('MyApp::Results');

Class to be used by L</"query">, defaults to L<Mojo::Pg::Results>. Note that
this class needs to have already been loaded before L</"query"> is called.

=head1 METHODS

L<Mojo::Pg::Database> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 begin

  my $tx = $db->begin;
  my $tx = $db->begin('serializable');

Begin transaction and return L<Mojo::Pg::Transaction> object, which will
automatically roll back the transaction unless
L<Mojo::Pg::Transaction/"commit"> has been called before it is destroyed.
You can also pass isolation level for transaction.

  # Insert rows in a transaction
  eval {
    my $tx = $db->begin;
    $db->insert('frameworks', {name => 'Catalyst'});
    $db->insert('frameworks', {name => 'Mojolicious'});
    $tx->commit;
  };
  say $@ if $@;

=head2 delete

  my $results = $db->delete($table, \%where, \%options);

Generate a C<DELETE> statement with L<Mojo::Pg/"abstract"> (usually an
L<SQL::Abstract> object) and execute it with L</"query">. You can also append a
callback to perform operations non-blocking.

  $db->delete(some_table => sub {
    my ($db, $err, $results) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

Use all the same argument variations you would pass to the C<delete> method of
L<SQL::Abstract>.

  # "delete from some_table"
  $db->delete('some_table');

  # "delete from some_table where foo = 'bar'"
  $db->delete('some_table', {foo => 'bar'});

  # "delete from some_table where foo like '%test%'"
  $db->delete('some_table', {foo => {-like => '%test%'}});

  # "delete from some_table where foo = 'bar' returning id"
  $db->delete('some_table', {foo => 'bar'}, {returning => 'id'});

=head2 disconnect

  $db->disconnect;

Disconnect L</"dbh"> and prevent it from getting reused.

=head2 dollar_only

  $db = $db->dollar_only;

Activate C<pg_placeholder_dollaronly> for next L</"query"> call and allow C<?>
to be used as an operator.

  # Check for a key in a JSON document
  $db->dollar_only->query('select * from foo where bar ? $1', 'baz')
    ->expand->hashes->map(sub { $_->{bar}{baz} })->join("\n")->say;

=head2 insert

  my $results = $db->insert($table, \@values || \%fieldvals, \%options);

Generate an C<INSERT> statement with L<Mojo::Pg/"abstract"> (usually an
L<SQL::Abstract> object) and execute it with L</"query">. You can also append a
callback to perform operations non-blocking.

  $db->insert(some_table => {foo => 'bar'} => sub {
    my ($db, $err, $results) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

Use all the same argument variations you would pass to the C<insert> method of
L<SQL::Abstract>.

  # "insert into some_table (foo, baz) values ('bar', 'yada')"
  $db->insert('some_table', {foo => 'bar', baz => 'yada'});

  # "insert into some_table (foo) values ({1,2,3})"
  $db->insert('some_table', {foo => [1, 2, 3]});

  # "insert into some_table (foo) values ('bar') returning id"
  $db->insert('some_table', {foo => 'bar'}, {returning => 'id'});

  # "insert into some_table (foo) values ('bar') returning id, foo"
  $db->insert('some_table', {foo => 'bar'}, {returning => ['id', 'foo']});

=head2 is_listening

  my $bool = $db->is_listening;

Check if L</"dbh"> is listening for notifications.

=head2 listen

  $db = $db->listen('foo');

Subscribe to a channel and receive L</"notification"> events when the
L<Mojo::IOLoop> event loop is running.

=head2 notify

  $db = $db->notify('foo');
  $db = $db->notify(foo => 'bar');

Notify a channel.

=head2 pid

  my $pid = $db->pid;

Return the process id of the backend server process.

=head2 ping

  my $bool = $db->ping;

Check database connection.

=head2 query

  my $results = $db->query('select * from foo');
  my $results = $db->query('insert into foo values (?, ?, ?)', @values);
  my $results = $db->query('select ?::json as foo', {json => {bar => 'baz'}});

Execute a blocking L<SQL|http://www.postgresql.org/docs/current/static/sql.html>
statement and return a results object based on L</"results_class"> (which is
usually L<Mojo::Pg::Results>) with the query results. The L<DBD::Pg> statement
handle will be automatically reused when it is not active anymore, to increase
the performance of future queries. You can also append a callback to perform
operations non-blocking.

  $db->query('insert into foo values (?, ?, ?)' => @values => sub {
    my ($db, $err, $results) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

Hash reference arguments containing a value named C<json>, will be encoded to
JSON text with L<Mojo::JSON/"to_json">. To accomplish the reverse, you can use
the method L<Mojo::Pg::Results/"expand">, which automatically decodes all fields
of the types C<json> and C<jsonb> with L<Mojo::JSON/"from_json"> to Perl values.

  # "I ♥ Mojolicious!"
  $db->query('select ?::jsonb as foo', {json => {bar => 'I ♥ Mojolicious!'}})
    ->expand->hash->{foo}{bar};

Hash reference arguments containing values named C<type> and C<value>, can be
used to bind specific L<DBD::Pg> data types to placeholders.

  # Insert binary data
  use DBD::Pg ':pg_types';
  $db->query('insert into bar values (?)', {type => PG_BYTEA, value => $bytes});

=head2 select

  my $results = $db->select($source, $fields, $where, $order);

Generate a C<SELECT> statement with L<Mojo::Pg/"abstract"> (usually an
L<SQL::Abstract> object) and execute it with L</"query">. You can also append a
callback to perform operations non-blocking.

  $db->select(some_table => ['foo'] => {bar => 'yada'} => sub {
    my ($db, $err, $results) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

Use all the same argument variations you would pass to the C<select> method of
L<SQL::Abstract>.

  # "select * from some_table"
  $db->select('some_table');

  # "select id, foo from some_table"
  $db->select('some_table', ['id', 'foo']);

  # "select * from some_table where foo = 'bar'"
  $db->select('some_table', undef, {foo => 'bar'});

  # "select * from some_table where foo = 'bar' order by id desc"
  $db->select('some_table', undef, {foo => 'bar'}, {-desc => 'id'});

  # "select * from some_table where foo like '%test%'"
  $db->select('some_table', undef, {foo => {-like => '%test%'}});

=head2 tables

  my $tables = $db->tables;

Return table and view names for this database, that are visible to the current
user and not internal, as an array reference.

  # Names of all tables
  say for @{$db->tables};

=head2 unlisten

  $db = $db->unlisten('foo');
  $db = $db->unlisten('*');

Unsubscribe from a channel, C<*> can be used to unsubscribe from all channels.

=head2 update

  my $results = $db->update($table, \%fieldvals, \%where, \%options);

Generate an C<UPDATE> statement with L<Mojo::Pg/"abstract"> (usually an
L<SQL::Abstract> object) and execute it with L</"query">. You can also append a
callback to perform operations non-blocking.

  $db->update(some_table => {foo => 'baz'} => {foo => 'bar'} => sub {
    my ($db, $err, $results) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

Use all the same argument variations you would pass to the C<update> method of
L<SQL::Abstract>.

  # "update some_table set foo = 'bar' where id = 23"
  $db->update('some_table', {foo => 'bar'}, {id => 23});

  # "update some_table set foo = {1,2,3} where id = 23"
  $db->update('some_table', {foo => [1, 2, 3]}, {id => 23});

  # "update some_table set foo = 'bar' where foo like '%test%'"
  $db->update('some_table', {foo => 'bar'}, {foo => {-like => '%test%'}});

  # "update some_table set foo = 'bar' where id = 23 returning id"
  $db->update('some_table', {foo => 'bar'}, {id => 23}, {returning => 'id'});

=head1 SEE ALSO

L<Mojo::Pg>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
