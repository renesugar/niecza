our ($OpSimplePair, $OpCallSub, $OpLexical, $OpBuiltin, $OpTake,
     $OpControl, $OpMakeJunction, $OpGeneralConst);
our ($PassSimplifier);

class NieczaPassSimplifier;

# This optimization pass handles lowering calls to well-known functions

method invoke($*unit) {
    # XXX enter and sigs need love
    $*unit.visit_local_subs_postorder(-> $su {
        $su.code = run_optree($su, $su.code, 1)
    });
    $*unit
}

method invoke_incr($sub, $ops) {
    my $*where = False;
    run_optree($sub, $ops, 1);
}

# sub sorry($msg) {
#     die "No position info to report ($msg)" unless $*where;
#     $*where.CURSOR.sorry($msg);
# }

sub worry($msg) {
    die "No position info to report ($msg)" unless $*where;
    $*where.CURSOR.worry($msg);
}

sub no_named_params($op) {
    if defined $op.args {
        for @( $op.args ) -> $a {
            if $a.^isa($OpSimplePair) {
                return Any;
            } elsif $a.^isa($OpCallSub) && $a.invocant.^isa($OpLexical)
                    && $a.invocant.name eq '&prefix:<|>' {
                return Any;
            }
        }
    }
    ($op.args // $op.positionals);
}

sub capture_params($op) {
    if !defined $op.args {
        return ($op.positionals);
    }

    my @named;
    my @pos;

    for @( $op.args ) -> $a {
        if $a.^isa($OpSimplePair) {
            push @named, $a.key => $a.value;
        } elsif $a.^isa($OpCallSub) && $a.invocant.^isa($OpLexical)
                && $a.invocant.name eq '&prefix:<|>' {
            return Nil;
        } else {
            push @pos, $a;
        }
    }

    $(@pos), @named;
}

our %funcs = (
    '&postcircumfix:<{ }>' => &do_atkey,
    '&postcircumfix:<[ ]>' => &do_atpos,

    '&last'                => do_nullary_control(2),
    '&next'                => do_nullary_control(1),
    '&proceed'             => do_nullary_control(7),
    '&term:<proceed>'      => do_nullary_control(7),
    '&redo'                => do_nullary_control(3),

    '&infix:<&>'           => do_makejunction(0),
    '&infix:<^>'           => do_makejunction(2),
    '&infix:<|>'           => do_makejunction(3),
    '&all'                 => do_makejunction(8),
    '&none'                => do_makejunction(9),
    '&one'                 => do_makejunction(10),
    '&any'                 => do_makejunction(11),

    '&return'              => &do_return_take,
    '&succeed'             => &do_return_take,
    '&take'                => &do_return_take,
);

sub do_builtin($name, $expect) { sub ($body, $nv, $invname, $op) { #OK not used
    return $op unless defined my $args = no_named_params($op);
    return $op unless $args ~~ $expect;
    return $OpBuiltin.new(pos => $op.pos, name => $name, args => $args);
} }

sub do_return_take($body, $nv, $invname, $op) { #OK not used
    return $op unless defined my $args = no_named_params($op);
    my $parcel = ($args == 1 ?? $args[0] !!
        $args == 0 ?? $OpLexical.new(pos => $op.pos, name => 'Nil') !!
        $OpCallSub.new(invocant => $OpLexical.new(name => '&infix:<,>'),
            pos => $op.pos, positionals => [@$args]));
    return ($invname eq '&take' ??
        $OpTake.new(pos => $op.pos, value => $parcel) !!
        $OpControl.new(pos => $op.pos, payload => $parcel,
            number => $invname eq '&return' ?? 4 !! 6));
}

sub do_nullary_control($number) { sub ($body, $nv, $ , $op) { #OK not used
    return $op unless defined my $args = no_named_params($op);
    return $op unless $args == 0;
    return $OpControl.new(:$number, pos => $op.pos, payload => $OpLexical.new(name => 'Nil'));
} }

sub do_makejunction($typecode) { sub ($body, $nv, $ , $op) { #OK not used
    return $op unless defined my $args = no_named_params($op);
    return $OpMakeJunction.new(pos => $op.pos, :$typecode, zyg => @$args);
} }

sub do_atkey($body, $nv, $invname, $op) { #OK not used
    my ($args, %named) = capture_params($op);
    return $op unless defined($args) && $args == 2;
    my $delete = %named<delete>:delete;
    my $exists = %named<exists>:delete;
    return $op if %named;
    return $op if $delete && (!$delete.^isa($OpLexical) || $delete.name ne 'True');
    return $op if $exists && (!$exists.^isa($OpLexical) || $exists.name ne 'True');
    return $op if $delete && $exists;
    return $OpBuiltin.new(pos => $op.pos, name => ($delete ?? 'delete_key' !!
            $exists ?? 'exists_key' !! 'at_key'), args => $args);
}

sub do_atpos($body, $nv, $invname, $op) { #OK not used
    return $op unless defined my $args = no_named_params($op);
    return $op unless $args == 2;
    return $OpBuiltin.new(pos => $op.pos, name => 'at_pos', args => $args);
}

# XXX should support folding of SimplePair, SimpleParcel too
sub check_folding($body, $sub, $op) {
    my @evargs;
    for $op.getargs -> $aop {
        my $name;
        if $aop.^isa($OpSimplePair) {
            $name = $aop.key;
            $aop := $aop.value;
        }
        push @evargs, $name, ($aop.const_value($body) // return);
    }

    my $ret = $*unit.constant_fold($sub, @evargs) // return;
    if $ret.^isa(Str) {
        $ret ~~ / $$ /;
        worry "Operation cannot succeed (constant folding threw exception: $/.prematch())";
        return;
    }
    $OpGeneralConst.new(pos => $op.pos, value => $ret);
}

sub run_optree($body, $op, $nv) {
    die "WTF in $body.name()" if !defined $op;
    my @kids := flat($op.ctxzyg($nv));
    temp $*where; $*where = $op.pos // $*where;
    my $i = 0;
    while $i < @kids {
        @kids[$i] = run_optree($body, @kids[$i], @kids[$i+1]);
        $i = $i + 2;
    }

    return $op unless $op.^isa($OpCallSub);
    my $inv = $op.invocant;
    return $op unless $inv.^isa($OpLexical);
    my $invname = $inv.name;
    my @inv_lex = $body.lookup_lex($invname);
    return $op unless @inv_lex;
    @inv_lex = $body.lookup_lex($invname ~ ':(!proto)')
        if @inv_lex[0] eq 'dispatch' &&
            @inv_lex[4].has_lexical($invname ~ ':(!proto)');
    return $op unless @inv_lex[0] eq 'sub';

    if @inv_lex[4].get_extend('pure') {
        # note, we have to use the real dispatcher here!  don't look past it
        # to the proto
        my @real_lex = $body.lookup_lex($invname);
        my $sub = @real_lex[0] eq 'sub' ?? @real_lex[4] !! @real_lex[5];
        if check_folding($body, $sub, $op) -> $nop { return $nop }
    }

    if @inv_lex[4].get_extend('builtin') -> $B {
        return $op unless defined my $args = no_named_params($op);
        return $op unless $args >= $B[1] &&
            (!defined($B[2]) || $args <= $B[2]);
        return $OpBuiltin.new(pos => $op.pos, name => $B[0], args => $args);
    }

    return $op unless @inv_lex[4].unit.name eq 'CORE';
    return $op unless my $func = %funcs{$invname};

    $func($body, $nv, $invname, $op);
}

INIT { $PassSimplifier = NieczaPassSimplifier; }
