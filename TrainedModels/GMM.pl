use strict;
use warnings;
use Data::Dump qw(dump);
use sml qw(show_plot);
use AI::MXNet qw(mx nd);
use List::Util qw(shuffle);

# =========================================================================
# 1. TAXONOMÍA DE COLUMNAS
# =========================================================================

my @metadata_cols = qw(minute hour day month year);

my @categorical_cols = qw(candle_type ob_type);

my @binary_cols = qw(
  pivote pivote3 pivote5 pivote10 pivote15
  trend_ext bos_ext bos_int choch_ext choch_int
  eqh eql inside_fvg inside_order_block
  lq_sweep_bsl lq_sweep_ssl lq_grab lq_run
  is_sh is_sl
  trend_int_15min trend_int_30min trend_int_1hr trend_int_2hr trend_int_4hr
  half_trend super_trend range_filter
);

my @bars_since_cols = qw(
  bars_since_eqh bars_since_eql bars_since_bos bars_since_choch
  bars_since_fvg bars_since_ob bars_since_lq_event
);

my $SENTINEL = -1;

my @continuous_cols = (
  'open (pip)', 'high (pip)', 'low (pip)', 'close (pip)', 'volume', 'atr (pct)', 
  'body', 'upper_wick', 'lower_wick', 'momentum', 'lenght',
  'distance_eqh', 'distance_eql', 'distance_bos', 'distance_choch',
  'distance_fvg', 'fvg_size', 'distance_ob', 'distance_hh', 'distance_ll',
  'nearest_fib_level',
  'distance_daily_high', 'distance_daily_low',
  'distance_weekly_high', 'distance_weekly_low',
  'distance_monthly_high', 'distance_monthly_low',
  'distance_bsl', 'distance_ssl', 'distance_sh', 'distance_sl',
  'distance_high_half_trend', 'distance_low_half_trend',
  'distance_high_super_trend', 'distance_low_super_trend',
  'distance_high_range_filter', 'distance_low_range_filter',
  'session_vwap_distance', 'open_vwap_distance', 'bos_vwap_distance',
  'choch_vwap_distance', 'pivot_vwap_distance',
  'poc', 'vah', 'val'
);

my @gmm_liquidity_cols = qw(
  distance_ob
  distance_fvg fvg_size
  nearest_fib_level
  session_vwap_distance open_vwap_distance bos_vwap_distance
  choch_vwap_distance pivot_vwap_distance
  poc vah val
  distance_bos distance_choch
  distance_eqh distance_eql
  distance_daily_high distance_daily_low
  distance_weekly_high distance_weekly_low
  distance_monthly_high distance_monthly_low
  distance_bsl distance_ssl distance_sh distance_sl
);

sml->add_to_class('metadata_cols', sub { return \@metadata_cols; });
sml->add_to_class('categorical_cols', sub { return \@categorical_cols; });
sml->add_to_class('binary_cols', sub { return \@binary_cols; });
sml->add_to_class('bars_since_cols', sub { return \@bars_since_cols; });
sml->add_to_class('continuous_cols', sub { return \@continuous_cols; });
sml->add_to_class('gmm_liquidity_cols', sub { return \@gmm_liquidity_cols; });


# =========================================================================
# 2. ESTANDARIZACIÓN ROBUSTA (Mediana e IQR)
# =========================================================================

sub column_quartiles {
  my ($self, $X) = @_;
  my ($N, $D) = @{$X->shape};
  my (@medians, @iqrs);

  for my $d (0 .. $D - 1) {
    my @vals = @{ $X->slice(':', $d)->asarray };
    my @sorted = sort { $a <=> $b } @vals;
    my $median = $sorted[int($N * 0.50)];
    my $q1     = $sorted[int($N * 0.25)];
    my $q3     = $sorted[int($N * 0.75)];
    push @medians, $median;
    push @iqrs, ($q3 - $q1) || 1e-6;
  }
  return (nd->array(\@medians), nd->array(\@iqrs));
}
sml->add_to_class('column_quartiles', \&column_quartiles);

sub robust_standardize_dataset {
  my ($self, $X, $medians, $iqrs) = @_;
  return nd->broadcast_div(nd->broadcast_sub($X, $medians), $iqrs);
}
sml->add_to_class('robust_standardize_dataset', \&robust_standardize_dataset);


# =========================================================================
# 3. ENSAMBLADO DE FEATURES
# =========================================================================

sub build_feature_matrix {
  my ($self, $data_hash) = @_;
  my @feature_cols;
  my @columns;

  my @continuous_present = grep { exists $data_hash->{$_} } @continuous_cols;
  if (@continuous_present) {
    my @raw_cols = map { nd->array($data_hash->{$_}) } @continuous_present;
    my $X_cont = nd->stack(@raw_cols, axis => 1);
    my ($medians, $iqrs) = sml->column_quartiles($X_cont);
    my $X_cont_scaled = sml->robust_standardize_dataset($X_cont, $medians, $iqrs);
    for my $i (0 .. $#continuous_present) {
      push @columns, $X_cont_scaled->slice(':', $i);
      push @feature_cols, $continuous_present[$i];
    }
  }

  for my $col (@bars_since_cols) {
    next unless exists $data_hash->{$col};
    my $vals = $data_hash->{$col};
    my (@flag, @count);
    for my $v (@$vals) {
      if ($v == $SENTINEL) {
        push @flag, 0; push @count, 0;
      } else {
        push @flag, 1; push @count, log(1 + $v);
      }
    }
    push @columns, nd->array(\@flag);
    push @feature_cols, "${col}_ocurrio";
    push @columns, nd->array(\@count);
    push @feature_cols, "${col}_log1p";
  }

  for my $col (@binary_cols) {
    next unless exists $data_hash->{$col};
    push @columns, nd->array($data_hash->{$col});
    push @feature_cols, $col;
  }

  for my $col (@categorical_cols) {
    next unless exists $data_hash->{$col};
    my $vals = $data_hash->{$col};
    my %levels;
    $levels{$_}++ for @$vals;
    my @level_names = sort keys %levels;
    for my $lvl (@level_names) {
      my @onehot = map { $_ eq $lvl ? 1 : 0 } @$vals;
      push @columns, nd->array(\@onehot);
      push @feature_cols, "${col}_${lvl}";
    }
  }
   if (scalar(@columns) == 0) {
      die "\n[ERROR CRÍTICO] La matriz de características está vacía.\n" .
          "El script no encontró NINGUNA coincidencia entre tu taxonomía y el archivo.\n" .
          "Esto es lo que Text::CSV realmente leyó como cabeceras:\n" . 
          dump([keys %$data_hash]) . "\n";
  }
  my $X = nd->stack(@columns, axis => 1);
  return ($X, \@feature_cols);
}
sml->add_to_class('build_feature_matrix', \&build_feature_matrix);

sub select_gmm_columns {
  my ($self, $X, $feature_cols) = @_;
  my %wanted = map { $_ => 1 } @gmm_liquidity_cols;
  my @keep_idx  = grep { $wanted{ $feature_cols->[$_] } } 0 .. $#$feature_cols;
  my @keep_names = @{$feature_cols}[@keep_idx];
  my $X_gmm = nd->take($X, nd->array(\@keep_idx), axis => 1);
  return ($X_gmm, \@keep_names);
}
sml->add_to_class('select_gmm_columns', \&select_gmm_columns);


# =========================================================================
# 4. GMM CON COVARIANZA DIAGONAL (Optimizada Asíncrona)
# =========================================================================

sub initialize_parameters_diag {
  my ($self, $X, $K, $method) = @_;
  my ($N, $D) = @{$X->shape};
  $method //= 'random_from_data';

  my $means;
  if ($method eq 'random_from_data') {
    my @all_idx = (0 .. $N - 1);
    my @shuffled = shuffle(@all_idx);
    my $indices = nd->array([ @shuffled[0 .. $K - 1] ]);
    $means = nd->take($X, $indices, axis => 0);
  } else {
    $means = nd->random->uniform(low => -1.0, high => 1.0, shape => [$K, $D]);
  }

  # ¡CORRECCIÓN! Mantenemos todo en el espacio de tensores de MXNet[cite: 1]
  my $global_var = nd->var($X, axis => 0) + 1e-6;
  my @vars = map { $global_var->copy } 1 .. $K;

  my $weights = nd->ones([$K]) / $K;
  my ($resp, $lower) = sml->e_step_diag($X, $means, \@vars, $weights);
  return $resp;
}
sml->add_to_class('initialize_parameters_diag', \&initialize_parameters_diag);

sub estimate_log_gaussian_prob_diag {
  my ($self, $X, $mean, $var) = @_;
  my ($N, $D) = @{$X->shape};

  my $var_reg = $var + 1e-6;
  my $diff = nd->broadcast_sub($X, $mean);
  my $quad = nd->broadcast_div(nd->square($diff), $var_reg);
  my $log_det = nd->sum(nd->log($var_reg));
  my $pi = 3.141592653589793;

  my $log_prob = -0.5 * ($D * log(2 * $pi) + $log_det + nd->sum($quad, axis => 1));
  return $log_prob;
}
sml->add_to_class('estimate_log_gaussian_prob_diag', \&estimate_log_gaussian_prob_diag);

sub e_step_diag {
  my ($self, $X, $means, $vars, $weights) = @_;
  my $K = $weights->shape->[0];
  my @cols;

  for my $k (0 .. $K - 1) {
    my $log_prob = sml->estimate_log_gaussian_prob_diag($X, $means->slice($k), $vars->[$k]);
    my $w_k = $weights->slice([$k, $k + 1]);
    push @cols, $log_prob + nd->log($w_k);
  }

  my $log_resp = nd->stack(@cols, axis => 1);
  my $max_log = $log_resp->max(axis => 1, keepdims => 1);
  my $log_sum_exp = $max_log + nd->log(
    nd->exp(nd->broadcast_sub($log_resp, $max_log))->sum(axis => 1, keepdims => 1)
  );

  my $responsibilities = nd->exp(nd->broadcast_sub($log_resp, $log_sum_exp));
  my $lower_bound = $log_sum_exp->sum; 
  return ($responsibilities, $lower_bound);
}
sml->add_to_class('e_step_diag', \&e_step_diag);

sub m_step_diag {
  my ($self, $X, $resp) = @_;
  my ($N, $D) = @{$X->shape};
  my $K = $resp->shape->[1];

  my $Nk = $resp->sum(axis => 0);
  my $weights = $Nk / $N;
  my (@means, @vars);

  for my $k (0 .. $K - 1) {
    my $nk_tensor = nd->maximum_scalar($Nk->slice([$k, $k + 1]), 1e-10);
    my $r = $resp->slice(':', $k)->reshape([-1, 1]);
    
    my $mean = nd->sum(nd->broadcast_mul($X, $r), axis => 0) / $nk_tensor;
    push @means, $mean;

    my $diff = nd->broadcast_sub($X, $mean);
    my $var = nd->sum(nd->broadcast_mul(nd->square($diff), $r), axis => 0) / $nk_tensor;
    push @vars, $var;
  }

  return (nd->stack(@means), \@vars, $weights);
}
sml->add_to_class('m_step_diag', \&m_step_diag);

sub fit_diag {
  my ($self, $X, $K, %args) = @_;
  my $max_iter   = $args{max_iter}    // 100;
  my $tol        = $args{tol}         // 1e-3;
  my $init_param = $args{init_params} // 'random_from_data';

  my $resp = sml->initialize_parameters_diag($X, $K, $init_param);
  my $lower_old = -1e100;
  my @history;
  my ($means, $vars, $weights);
  my $N = $X->len;
  my $has_converged = 0;

  for my $iter (1 .. $max_iter) {
    ($means, $vars, $weights) = sml->m_step_diag($X, $resp);
    my $lower;
    ($resp, $lower) = sml->e_step_diag($X, $means, $vars, $weights);

    # Este es el único asscalar estrictamente necesario para romper el bucle en Perl.
    my $lower_scalar = $lower->asscalar;
    push @history, $lower_scalar;

    my $diff = abs($lower_scalar - $lower_old) / $N;
    if ($diff < $tol) {
      $has_converged = 1;
      print "Convergencia Diagonal alcanzada en iteración $iter.\n";
      last;
    }
    $lower_old = $lower_scalar;
  }

  warn "\nAviso de convergencia: no convergió en $max_iter iteraciones.\n" unless $has_converged;
  return ($resp, $means, $vars, $weights, \@history);
}
sml->add_to_class('fit_diag', \&fit_diag);


# =========================================================================
# 5. SELECCIÓN DE K VÍA BIC (Diag)
# =========================================================================

sub compute_bic {
  my ($self, $log_likelihood, $N, $D, $K) = @_;
  my $n_params = $K * $D * 2 + ($K - 1);
  return -2 * $log_likelihood + $n_params * log($N);
}
sml->add_to_class('compute_bic', \&compute_bic);

sub select_k_by_bic {
  my ($self, $X, %args) = @_;
  my @k_range = @{ $args{k_range} // [2, 3, 4, 5, 6, 7, 8] };
  my ($N, $D) = @{$X->shape};

  my %results;
  for my $K (@k_range) {
    my ($resp, $means, $vars, $weights, $history) = sml->fit_diag(
      $X, $K, max_iter => $args{max_iter} // 100, tol => $args{tol} // 1e-4, init_params => $args{init_params} // 'random_from_data',
    );
    my $final_ll = ref($history->[-1]) ? $history->[-1]->asscalar : $history->[-1];
    my $bic = sml->compute_bic($final_ll, $N, $D, $K);
    $results{$K} = { bic => $bic, resp => $resp, means => $means, vars => $vars, weights => $weights, log_likelihood => $final_ll };
    printf "K=%d  log-likelihood=%.4f  BIC=%.4f\n", $K, $final_ll, $bic;
  }

  my ($best_k) = sort { $results{$a}{bic} <=> $results{$b}{bic} } keys %results;
  printf "\nMejor K según BIC (Diag): %d\n", $best_k;
  return ($best_k, $results{$best_k}, \%results);
}
sml->add_to_class('select_k_by_bic', \&select_k_by_bic);


# =========================================================================
# 6. PODA DE COLINEALIDAD (Previo a covarianza full)
# =========================================================================

sub compute_correlation_matrix {
  my ($self, $X) = @_;
  my ($N, $D) = @{$X->shape};
  my $mean = nd->mean($X, axis => 0);
  my $std  = nd->sqrt(nd->var($X, axis => 0)) + 1e-8;
  my $Xs   = nd->broadcast_div(nd->broadcast_sub($X, $mean), $std);
  my $corr = nd->dot($Xs->T, $Xs) / $N;
  return $corr;
}
sml->add_to_class('compute_correlation_matrix', \&compute_correlation_matrix);

sub prune_correlated_features {
  my ($self, $X, $feature_names, %args) = @_;
  my $threshold = $args{threshold} // 0.90;
  my ($N, $D) = @{$X->shape};
  my $corr = sml->compute_correlation_matrix($X + 0)->asarray;

  my @avg_abs_corr;
  for my $i (0 .. $D - 1) {
    my $sum = 0;
    for my $j (0 .. $D - 1) {
      next if $i == $j;
      $sum += abs($corr->[$i][$j]);
    }
    $avg_abs_corr[$i] = $sum / ($D - 1);
  }

  my %dropped;
  for my $i (0 .. $D - 1) {
    next if $dropped{$i};
    for my $j ($i + 1 .. $D - 1) {
      next if $dropped{$j};
      if (abs($corr->[$i][$j]) > $threshold) {
        my $victim = $avg_abs_corr[$i] >= $avg_abs_corr[$j] ? $i : $j;
        $dropped{$victim} = 1;
        printf "Podado '%s' (corr=%.3f con '%s')\n", $feature_names->[$victim], $corr->[$i][$j], $feature_names->[$victim == $i ? $j : $i];
      }
    }
  }

  my @keep_idx = grep { !$dropped{$_} } 0 .. $D - 1;
  my @keep_names = @{$feature_names}[@keep_idx];
  my $X_pruned = nd->take($X, nd->array(\@keep_idx), axis => 1);

  printf "Features: %d -> %d tras poda de colinealidad (umbral |r|>%.2f)\n", $D, scalar(@keep_idx), $threshold;
  return ($X_pruned, \@keep_names);
}
sml->add_to_class('prune_correlated_features', \&prune_correlated_features);


# =========================================================================
# 7. GMM COVARIANZA FULL Y BIC (Optimizada Asíncrona)
# =========================================================================

sub initialize_parameters {
  my ($self, $X, $K, $method) = @_;
  my ($N, $D) = @{$X->shape};
  $method //= 'random_from_data';

  if ($method eq 'random_from_data') {
    my @all_idx = (0 .. $N - 1);
    my @shuffled = shuffle(@all_idx);
    my $indices = nd->array([ @shuffled[0 .. $K - 1] ]);
    
    my $means = nd->take($X, $indices, axis => 0);
    my @covs = map { nd->eye($D) * 0.01 } 1 .. $K;
    my $weights = nd->ones([$K]) / $K;
    my ($resp, $lower) = sml->e_step($X, $means, \@covs, $weights);
    return $resp;
  } elsif ($method eq 'random') {
    my $means = nd->random->uniform(low => 0.0, high => 1.0, shape => [$K, $D]);
    my @covs = map { nd->eye($D) * 0.01 } 1 .. $K;
    my $weights = nd->ones([$K]) / $K;
    my ($resp, $lower) = sml->e_step($X, $means, \@covs, $weights);
    return $resp;
  } else {
    die "Método de inicialización desconocido: $method";
  }
}
sml->add_to_class('initialize_parameters', \&initialize_parameters);

sub estimate_log_gaussian_prob {
  my ($self, $X, $mean, $cov) = @_;
  my ($N, $D) = @{$X->shape};

  my $cov_stable = $cov + (nd->eye($D) * 1e-6);
  my $L = nd->linalg->potrf($cov_stable); 

  my @diag_elements;
  for my $i (0 .. $D - 1) { push @diag_elements, nd->log($L->slice($i, $i)); }
  my $log_det = nd->add_n(@diag_elements) * 2.0;

  my $X_centered = nd->broadcast_sub($X, $mean)->T;
  my $Y = nd->linalg->trsm($L, $X_centered, alpha => 1.0, rightside => 0, lower => 1, transpose => 0);
  my $quad = nd->sum(nd->square($Y), axis => 0);
  my $pi = 3.141592653589793;

  return -0.5 * ( $D * log(2 * $pi) + $log_det + $quad );
}
sml->add_to_class('estimate_log_gaussian_prob', \&estimate_log_gaussian_prob);

sub e_step {
  my ($self, $X, $means, $covs, $weights) = @_;
  my $K = $weights->shape->[0];
  my @cols;

  for my $k (0 .. $K - 1) {
    my $log_prob = sml->estimate_log_gaussian_prob($X, $means->slice($k), $covs->[$k]);
    my $w_k = $weights->slice([$k, $k + 1]);
    push @cols, $log_prob + nd->log($w_k);
  }

  my $log_resp = nd->stack(@cols, axis => 1);
  my $max_log = $log_resp->max(axis => 1, keepdims => 1);
  my $log_sum_exp = $max_log + nd->log(
    nd->exp(nd->broadcast_sub($log_resp, $max_log))->sum(axis => 1, keepdims => 1)
  );

  my $responsibilities = nd->exp(nd->broadcast_sub($log_resp, $log_sum_exp));
  my $lower_bound = $log_sum_exp->sum;
  return ($responsibilities, $lower_bound);
}
sml->add_to_class('e_step', \&e_step);

sub m_step {
  my ($self, $X, $resp) = @_;
  my ($N, $D) = @{$X->shape};
  my $K = $resp->shape->[1];

  my $Nk = $resp->sum(axis => 0);
  my $weights = $Nk / $N;
  my (@means, @covs);

  for my $k (0 .. $K - 1) {
    my $nk_tensor = nd->maximum_scalar($Nk->slice([$k, $k + 1]), 1e-10);
    my $r = $resp->slice(':', $k)->reshape([-1, 1]);

    my $mean = nd->sum(nd->broadcast_mul($X, $r), axis => 0) / $nk_tensor;
    push @means, $mean;

    my $diff = nd->broadcast_sub($X, $mean);
    my $weighted_diff = nd->broadcast_mul($diff, $r);
    my $cov = nd->dot($weighted_diff->T, $diff) / $nk_tensor;
    push @covs, $cov;
  }

  return (nd->stack(@means), \@covs, $weights);
}
sml->add_to_class('m_step', \&m_step);

sub fit {
  my ($self, $X, $K, %args) = @_;
  my $max_iter   = $args{max_iter}    // 100;
  my $tol        = $args{tol}         // 1e-3;
  my $init_param = $args{init_params} // 'random_from_data';

  my $resp = sml->initialize_parameters($X, $K, $init_param);
  my $lower_old = -1e100;
  my (@history, @plots);
  my ($means, $covs, $weights);
  my $N = $X->len;
  my $has_converged = 0;

  for my $iter (1 .. $max_iter) {
    ($means, $covs, $weights) = sml->m_step($X, $resp);
    my $lower;
    ($resp, $lower) = sml->e_step($X, $means, $covs, $weights);

    my $lower_scalar = $lower->asscalar;
    push @history, $lower_scalar;
    
    if ($args{plot_steps}) {
        my $assignments = nd->argmax($resp, axis => 1);
        push @plots, sml->plot_current_state($X, $means, $covs, $assignments, $iter, $args{header}, $K);
    }
    
    my $diff = abs($lower_scalar - $lower_old) / $N;
    if ($diff < $tol) {
      $has_converged = 1;
      print "Convergencia Full alcanzada en iteración $iter.\n";
      last;
    }
    $lower_old = $lower_scalar;
  }
  
  warn "\nAviso de convergencia: no convergió en $max_iter iteraciones.\n" unless $has_converged;
  return ($resp, $means, $covs, \@history, \@plots);
}
sml->add_to_class('fit', \&fit);

sub compute_bic_full {
  my ($self, $log_likelihood, $N, $D, $K) = @_;
  my $n_params = $K * $D + $K * $D * ($D + 1) / 2 + ($K - 1);
  return -2 * $log_likelihood + $n_params * log($N);
}
sml->add_to_class('compute_bic_full', \&compute_bic_full);

sub select_k_by_bic_full {
  my ($self, $X, %args) = @_;
  my @k_range = @{ $args{k_range} // [2, 3, 4, 5, 6, 7, 8] };
  my ($N, $D) = @{$X->shape};

  my %results;
  for my $K (@k_range) {
    my ($resp, $means, $covs, $history, $plots) = sml->fit(
      $X, $K, max_iter => $args{max_iter} // 100, tol => $args{tol} // 1e-4, init_params => $args{init_params} // 'random_from_data', plot_steps => 0,
    );
    my $final_ll = ref($history->[-1]) ? $history->[-1]->asscalar : $history->[-1];
    my $bic = sml->compute_bic_full($final_ll, $N, $D, $K);
    my $weights = $resp->sum(axis => 0) / $N;

    $results{$K} = { bic => $bic, resp => $resp, means => $means, covs => $covs, weights => $weights, log_likelihood => $final_ll };
    printf "K=%d  log-likelihood=%.4f  BIC=%.4f\n", $K, $final_ll, $bic;
  }

  my ($best_k) = sort { $results{$a}{bic} <=> $results{$b}{bic} } keys %results;
  printf "\nMejor K según BIC (Full): %d\n", $best_k;
  return ($best_k, $results{$best_k}, \%results);
}
sml->add_to_class('select_k_by_bic_full', \&select_k_by_bic_full);


# =========================================================================
# 8. PREDICCIÓN / INFERENCIA
# =========================================================================

sub gmm_predict {
  my ($self, $model_hash, $X_new) = @_;
  
  my $resp;
  if (exists $model_hash->{vars}) {
    ($resp, undef) = sml->e_step_diag($X_new, $model_hash->{means}, $model_hash->{vars}, $model_hash->{weights});
  } elsif (exists $model_hash->{covs}) {
    ($resp, undef) = sml->e_step($X_new, $model_hash->{means}, $model_hash->{covs}, $model_hash->{weights});
  } else {
    die "Error: El modelo GMM no tiene 'vars' ni 'covs' definidos.\n";
  }
  
  return nd->argmax($resp, axis => 1);
}
sml->add_to_class('gmm_predict', \&gmm_predict);

1;