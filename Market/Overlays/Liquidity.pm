package Market::Overlays::Liquidity;
use strict;
use warnings;
use parent 'Market::Overlays::Base';

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{active}          = exists $args{active} ? $args{active} : 1;
    $self->{show_bsl}        = exists $args{show_bsl} ? $args{show_bsl} : 1;
    $self->{show_ssl}        = exists $args{show_ssl} ? $args{show_ssl} : 1;
    $self->{show_equal}      = exists $args{show_equal} ? $args{show_equal} : 1;
    $self->{bsl_color}       = '#ef5350';
    $self->{ssl_color}       = '#26a69a';
    $self->{sweep_color}     = '#ff9800';
    $self->{grab_color}      = '#ff9800';
    $self->{run_color}       = '#2962ff';
    $self->{label_bg_color}  = '#fbfcf8';
    $self->{dash_style}      = [4, 4];
    $self->{max_visible}     = $args{max_visible} // 45;
    return $self;
}

sub render {
    my ($self, $start_index, $end_index, $scale) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas && $scale;
    $canvas->delete('liquidity_layer');
    return unless $self->{active};
    return unless $self->{engine} && $self->{engine}->{indicator_manager};

    my $manager = $self->{engine}->{indicator_manager};
    my $events = $manager->get('Liquidity');
    $events = [] unless $events && ref($events) eq 'ARRAY';

    my $liq_obj = $manager->can('get_indicator_object') ? $manager->get_indicator_object('Liquidity') : undef;
    my $equals = ($liq_obj && $liq_obj->can('get_equal_levels')) ? $liq_obj->get_equal_levels() : [];

    $self->_render_levels($events, $start_index, $end_index, $scale);
    $self->_render_equal_levels($equals, $start_index, $end_index, $scale) if $self->{show_equal};
}

sub _render_levels {
    my ($self, $levels, $start, $end, $scale) = @_;
    my $canvas = $self->{canvas};
    my @drawable;

    for my $lvl (@$levels) {
        next unless $lvl && ref($lvl) eq 'HASH';
        my $type = $lvl->{type} || '';
        next if $type eq 'BSL' && !$self->{show_bsl};
        next if $type eq 'SSL' && !$self->{show_ssl};
        next unless defined $lvl->{index} && defined $lvl->{price};
        next if $lvl->{index} > $end;

        my $finish = defined $lvl->{resolved_index} ? $lvl->{resolved_index} : $end;
        next if $finish < $start;
        next if $lvl->{index} > $end;
        push @drawable, $lvl;
    }

    @drawable = sort { ($b->{index} // 0) <=> ($a->{index} // 0) } @drawable;
    splice(@drawable, $self->{max_visible}) if @drawable > $self->{max_visible};
    @drawable = sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @drawable;

    my %label_rows;
    for my $lvl (@drawable) {
        my $type = $lvl->{type};
        my $price = $lvl->{price};
        my $x1 = $scale->index_to_center_x($lvl->{index});
        my $finish = defined $lvl->{resolved_index} ? $lvl->{resolved_index} : $end;
        $finish = $end if $finish > $end;
        my $x2 = $scale->index_to_center_x($finish);
        $x1 = 0 if $x1 < 0;
        $x2 = $scale->{width} - 4 if $x2 > $scale->{width} - 4;
        my $y = $scale->value_to_y($price);

        my ($color, $label) = $self->_style_for_level($lvl);
        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill => $color,
            -dash => $self->{dash_style},
            -width => 1,
            -tags => ['liquidity_layer']
        );

        my $dy = $type eq 'BSL' ? -9 : 9;
        my $row_key = int(($y + $dy) / 12);
        my $shift = ($label_rows{$row_key}++ || 0) * 9;
        $shift = -$shift if $type eq 'BSL';

        my $label_x = $x2 - 4;
        $label_x = 18 if $label_x < 18;
        $self->_draw_plain_label(
            x => $label_x,
            y => $y + $dy + $shift,
            text => $label,
            color => $color,
            anchor => 'e'
        );
    }
}

sub _style_for_level {
    my ($self, $lvl) = @_;
    my $type  = $lvl->{type} || '';
    my $state = $lvl->{state} || 'DETECTED';
    my $color = $type eq 'BSL' ? $self->{bsl_color} : $self->{ssl_color};
    my $label = $type;

    if ($state eq 'SWEEP') { $color = $self->{sweep_color}; $label = 'SWEEP'; }
    elsif ($state eq 'GRAB') { $color = $self->{grab_color}; $label = 'LQ GRAB'; }
    elsif ($state eq 'RUN')  { $color = $self->{run_color};  $label = 'LQ RUN'; }
    return ($color, $label);
}

sub _render_equal_levels {
    my ($self, $equals, $start, $end, $scale) = @_;
    return unless $equals && ref($equals) eq 'ARRAY';
    my $canvas = $self->{canvas};

    for my $eq (@$equals) {
        next unless $eq && ref($eq) eq 'HASH';
        next unless defined $eq->{index1} && defined $eq->{index2} && defined $eq->{price};
        next if $eq->{index2} < $start || $eq->{index1} > $end;

        my $x1 = $scale->index_to_center_x($eq->{index1});
        my $x2 = $scale->index_to_center_x($eq->{index2});
        $x1 = 0 if $x1 < 0;
        $x2 = $scale->{width} - 4 if $x2 > $scale->{width} - 4;
        my $y = $scale->value_to_y($eq->{price});
        my $type = $eq->{type} || '';
        my $color = $type eq 'EQH' ? $self->{bsl_color} : $self->{ssl_color};

        $canvas->createLine($x1, $y, $x2, $y, -fill => $color, -dash => [2, 3], -width => 1, -tags => ['liquidity_layer']);
        $self->_draw_plain_label(
            x => ($x1 + $x2) / 2,
            y => $y + ($type eq 'EQH' ? -10 : 10),
            text => $type,
            color => $color,
            anchor => 'center'
        );
    }
}

sub _draw_plain_label {
    my ($self, %args) = @_;
    my $canvas = $self->{canvas};
    return unless defined $args{x} && defined $args{y} && defined $args{text};
    my $txt = $canvas->createText(
        $args{x}, $args{y},
        -text   => $args{text},
        -fill   => $args{color} || '#131722',
        -font   => ['Helvetica', 7, 'bold'],
        -anchor => $args{anchor} || 'center',
        -tags   => ['liquidity_layer']
    );
    my @bbox = $canvas->bbox($txt);
    if (@bbox) {
        my $bg = $canvas->createRectangle(
            $bbox[0] - 3, $bbox[1] - 1, $bbox[2] + 3, $bbox[3] + 1,
            -fill => $self->{label_bg_color},
            -outline => '',
            -tags => ['liquidity_layer']
        );
        $canvas->lower($bg, $txt);
    }
}

1;
