package SQL::Abstract::Pg;
use Mojo::Base 'SQL::Abstract';

BEGIN { *puke = \&SQL::Abstract::puke }

sub insert {
  my ($self, $table, $data, $options) = @_;
  local @{$options}{qw(returning _pg_returning)} = (1, 1)
    if exists $options->{on_conflict} && !$options->{returning};
  return $self->SUPER::insert($table, $data, $options);
}

sub _insert_returning {
  my ($self, $options) = @_;

  delete $options->{returning} if $options->{_pg_returning};

  # ON CONFLICT
  my $sql = '';
  my @bind;
  if (exists $options->{on_conflict}) {
    my $conflict = $options->{on_conflict};
    my ($conflict_sql, @conflict_bind);
    $self->_SWITCH_refkind(
      $conflict => {
        ARRAYREF => sub {
          my ($fields, $set) = @$conflict;
          puke qq{ARRAYREF value "$fields" not allowed}
            unless ref $fields eq 'ARRAY';
          puke qq{ARRAYREF value "$set" not allowed} unless ref $set eq 'HASH';

          $conflict_sql
            = '(' . join(', ', map { $self->_quote($_) } @$fields) . ')';
          $conflict_sql .= $self->_sqlcase(' do update set ');
          my ($set_sql, @set_bind) = $self->_update_set_values($set);
          $conflict_sql .= $set_sql;
          push @conflict_bind, @set_bind;
        },
        ARRAYREFREF => sub { ($conflict_sql, @conflict_bind) = @$$conflict },
        SCALARREF => sub { $conflict_sql = $$conflict },
        UNDEF     => sub { $conflict_sql = $self->_sqlcase('do nothing') }
      }
    );
    $sql .= $self->_sqlcase(' on conflict ') . $conflict_sql;
    push @bind, @conflict_bind;
  }

  $sql .= $self->SUPER::_insert_returning($options) if $options->{returning};

  return $sql, @bind;
}

sub _order_by {
  my ($self, $options) = @_;

  # Legacy
  return $self->SUPER::_order_by($options)
    if ref $options ne 'HASH'
    or grep {/^-(?:desc|asc)/i} keys %$options;

  # GROUP BY
  my $sql = '';
  my @bind;
  if (defined(my $group = $options->{group_by})) {
    my $group_sql;
    $self->_SWITCH_refkind(
      $group => {
        ARRAYREF => sub {
          $group_sql = join ', ', map { $self->_quote($_) } @$group;
        },
        SCALARREF => sub { $group_sql = $$group }
      }
    );
    $sql .= $self->_sqlcase(' group by ') . $group_sql;
  }

  # ORDER BY
  $sql .= $self->_order_by($options->{order_by})
    if defined $options->{order_by};

  # LIMIT
  if (defined $options->{limit}) {
    $sql .= $self->_sqlcase(' limit ') . '?';
    push @bind, $options->{limit};
  }

  # OFFSET
  if (defined $options->{offset}) {
    $sql .= $self->_sqlcase(' offset ') . '?';
    push @bind, $options->{offset};
  }

  # FOR
  if (defined(my $for = $options->{for})) {
    my $for_sql;
    $self->_SWITCH_refkind(
      $for => {
        SCALAR => sub {
          puke qq{SCALAR value "$for" not allowed} unless $for eq 'update';
          $for_sql = $self->_sqlcase('UPDATE');
        },
        SCALARREF => sub { $for_sql .= $$for }
      }
    );
    $sql .= $self->_sqlcase(' for ') . $for_sql;
  }

  return $sql, @bind;
}

sub _table {
  my ($self, $table) = @_;

  return $self->SUPER::_table($table) unless ref $table eq 'ARRAY';

  my (@table, @join);
  for my $t (@$table) {
    if   (ref $t eq 'ARRAY') { push @join,  $t }
    else                     { push @table, $t }
  }

  $table = $self->SUPER::_table(\@table);
  for my $join (@join) {
    my ($name, $fk, $pk, $type) = @$join;
    $table
      .= $self->_sqlcase($type ? " $type join " : ' join ')
      . $self->_quote($name)
      . $self->_sqlcase(' on ') . '('
      . $self->_quote("$name.$fk") . ' = '
      . $self->_quote("$table[0].$pk") . ')';
  }

  return $table;
}

1;

=encoding utf8

=head1 NAME

SQL::Abstract::Pg - PostgreSQL Magic

=head1 SYNOPSIS

  my $abstract = SQL::Abstract::Pg->new;

=head1 DESCRIPTION

L<SQL::Abstract::Pg> extends L<SQL::Abstract> with a few PostgreSQL features
used by L<Mojo::Pg>.

=head1 INSERT

Additional C<INSERT> query features.

=head2 ON CONFLICT

The C<on_conflict> option can be used to generate C<INSERT> queries with
C<ON CONFLICT> clauses. So far C<undef> to pass C<DO NOTHING>, array references
to pass C<DO UPDATE> with conflict targets and a C<SET> expression, scalar
references to pass literal SQL and array reference references to pass literal
SQL with bind values are supported.

  # "insert into t (a) values ('b') on conflict do nothing"
  $abstract->insert('t', {a => 'b'}, {on_conflict => undef});

  # "insert into t (a) values ('b') on conflict do nothing"
  $abstract->insert('t', {a => 'b'}, {on_conflict => \'do nothing'});

This includes operations commonly referred to as C<upsert>.

  # "insert into t (a) values ('b') on conflict (a) do update set a = 'c'"
  $abstract->insert('t', {a => 'b'}, {on_conflict => [['a'], {a => 'c'}]);

  # "insert into t (a) values ('b') on conflict (a) do update set a = 'c'"
  $abstract->insert(
    't', {a => 'b'}, {on_conflict => \['(a) do update set a = ?', 'c']});

=head1 SELECT

Additional C<SELECT> query features.

=head2 ORDER BY

  $abstract->select($source, $fields, $where, $order);
  $abstract->select($source, $fields, $where, \%options);

Alternatively to the C<$order> argument accepted by L<SQL::Abstract> you can now
also pass a hash reference with various options. This includes C<order_by>,
which takes the same values as the C<$order> argument.

  # "select * from some_table order by foo desc"
  $abstract->select('some_table', '*', undef, {order_by => {-desc => 'foo'}});

=head2 LIMIT/OFFSET

The C<limit> and C<offset> options can be used to generate C<SELECT> queries
with C<LIMIT> and C<OFFSET> clauses.

  # "select * from some_table limit 10"
  $abstract->select('some_table', '*', undef, {limit => 10});

  # "select * from some_table offset 5"
  $abstract->select('some_table', '*', undef, {offset => 5});

  # "select * from some_table limit 10 offset 5"
  $abstract->select('some_table', '*', undef, {limit => 10, offset => 5});

=head2 GROUP BY

The C<group_by> option can be used to generate C<SELECT> queries with
C<GROUP BY> clauses. So far array references to pass a list of fields and scalar
references to pass literal SQL are supported.

  # "select * from some_table group by foo, bar"
  $abstract->select('some_table', '*', undef, {group_by => ['foo', 'bar']});

  # "select * from some_table group by foo, bar"
  $abstract->select('some_table', '*', undef, {group_by => \'foo, bar'});

=head2 FOR

The C<for> option can be used to generate C<SELECT> queries with C<FOR> clauses.
So far the scalar value C<update> to pass C<UPDATE> and scalar references to
pass literal SQL are supported.

  # "select * from some_table for update"
  $abstract->select('some_table', '*', undef, {for => 'update'});

  # "select * from some_table for update skip locked"
  $abstract->select('some_table', '*, undef, {for => \'update skip locked'});

=head2 JOIN

The C<$source> argument now also accepts array references containing not only
table names, but also array references with tables to generate C<JOIN> clauses
for.

  # "select * from foo join bar on (bar.foo_id = foo.id)"
  $abstract->select(['foo', ['bar', 'foo_id', 'id']]);

  # "select * from foo left join bar on (bar.foo_id = foo.id)"
  $abstract->select(['foo', ['bar', 'foo_id', 'id', 'left']]);

=head1 METHODS

L<SQL::Abstract::Pg> inherits all methods from L<SQL::Abstract>.

=head1 SEE ALSO

L<Mojo::Pg>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
