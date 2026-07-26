package TSNE {

  use strict;
  use warnings;
  use List::Util qw(max);
  use Data::Dump qw(dump);
  use AI::MXNet qw(mx nd);
  use Time::HiRes qw(time);
  use POSIX qw(ceil);
  
  our $MACHINE_EPSILON = 2.220446049250313e-16;
  
  sub new {
    my ($class, %args) = @_;
    
    my $self = {
        n_components              => $args{n_components} // 2,
        perplexity                => $args{perplexity} // 30.0,
        early_exaggeration        => $args{early_exaggeration} // 12.0,
        learning_rate             => $args{learning_rate} // 'auto',
        n_iter                    => $args{max_iter} // $args{n_iter} // 1000,
        n_iter_without_progress   => $args{n_iter_without_progress} // 300,
        n_iter_early_exaggeration => $args{n_iter_early_exaggeration} // 250,
        min_grad_norm             => $args{min_grad_norm} // 1e-7,
        metric                    => $args{metric} // 'euclidean',
        init                      => $args{init} // 'random',
        verbose                   => $args{verbose} // 0,
        random_state              => $args{random_state},
        method                    => $args{method} // 'exact',
        n_iter_check              => $args{n_iter_check} // 25,
        embedding_                => undef
    };

    return bless($self, $class);
  }

  # =====================================================================
  # OPTIMIZACIÓN: Retorna siempre Matriz Cuadrada 2D para evitar overhead
  # =====================================================================
  sub pdist {
    my ($self, $X) = @_;
    
    my $n_samples = $X->shape->[0];
      
    # ||x_i - x_j||^2 = x_i^2 - 2*x_i*x_j^T + x_j^2
    my $X_sum_squares = nd->sum(nd->square($X), axis => 1, keepdims => 1);
    my $dotXX = nd->dot($X, $X->T);
    my $sqdistances   = $X_sum_squares - (2.0 * $dotXX) + $X_sum_squares->T;
      
    # Prevenir ceros negativos y anular la diagonal consigo mismo
    my $diag_mask = nd->ones([$n_samples, $n_samples], dtype => 'float64') - nd->eye($n_samples, dtype => 'float64');
    $sqdistances = nd->maximum_scalar($sqdistances, 0.0) * $diag_mask;
      
    return $sqdistances; # Matriz cuadrada completa (NxN)
  }

  # Fully Vectorized _binary_search_perplexity
  sub _binary_search_perplexity_mxnet {
    my ($self, $sqdistances, $desired_perplexity, $verbose, $precomputed_beta) = @_;
    
    my ($n_samples, $n_neighbors) = @{$sqdistances->shape};
    my $sqdistances_f64 = $sqdistances->astype('float64');

    if (defined $precomputed_beta) {
      my $exponent = -$sqdistances_f64 * $precomputed_beta;
      my $floor_tensor = nd->ones($exponent->shape, dtype => 'float64') * -708.3964185322641;
      $exponent = $exponent->maximum($floor_tensor);
      my $row_P = nd->exp($exponent);
      
      if ($n_neighbors == $n_samples) {
          my $diag_mask = nd->ones([$n_samples, $n_neighbors], dtype => 'float64') - nd->eye($n_samples, dtype => 'float64');
          $row_P = $row_P * $diag_mask;
      }
      
      my $sum_Pi = nd->sum($row_P, axis => 1, keepdims => 1)->maximum($MACHINE_EPSILON);
      return $row_P / $sum_Pi; 
    }
    
    my $n_steps = 100;
    my $desired_entropy = log($desired_perplexity);
    
    my $beta     = nd->ones([$n_samples, 1], dtype => 'float64');
    my $beta_min = nd->ones([$n_samples, 1], dtype => 'float64') * -1e20;
    my $beta_max = nd->ones([$n_samples, 1], dtype => 'float64') * 1e20;
    
    my $diag_mask;
    if ($n_neighbors == $n_samples) {
      $diag_mask = nd->ones([$n_samples, $n_neighbors], dtype => 'float64') - nd->eye($n_samples, dtype => 'float64');
    }
    
    my $row_P_normalized;
  
    for my $step (0 .. $n_steps - 1) {
      my $exponent = -$sqdistances_f64 * $beta;
      
      my $floor_tensor = nd->ones($exponent->shape, dtype => 'float64') * -708.3964185322641;
      $exponent = $exponent->maximum($floor_tensor);
      
      my $row_P = nd->exp($exponent);
      
      if (defined $diag_mask) {
        $row_P = $row_P * $diag_mask; 
      }
      
      my $sum_Pi = nd->sum($row_P, axis => 1, keepdims => 1)->maximum($MACHINE_EPSILON);
      
      $row_P_normalized = $row_P / $sum_Pi;
      
      my $sum_disti_Pi = nd->sum($sqdistances_f64 * $row_P_normalized, axis => 1, keepdims => 1);
      
      my $entropy      = nd->log($sum_Pi) + $beta * $sum_disti_Pi;
      my $entropy_diff = $entropy - $desired_entropy;
      
      my $is_greater = ($entropy_diff > 0.0)->astype('float64');
      my $is_less    = nd->ones([$n_samples, 1], dtype => 'float64') - $is_greater;
      
      my $mask_max_init = ($beta_max >= 1e19)->astype('float64');
      my $mask_min_init = ($beta_min <= -1e19)->astype('float64');
      
      $beta_min = ($is_greater * $beta) + ($is_less * $beta_min);
      $beta_max = ($is_less * $beta)    + ($is_greater * $beta_max);
      
      my $b_greater_max_init = $beta * 2.0;
      my $b_greater_not_init = ($beta + $beta_max) / 2.0;
      my $b_less_min_init    = $beta / 2.0;
      my $b_less_not_init    = ($beta + $beta_min) / 2.0;
      
      $beta = ($is_greater * $mask_max_init * $b_greater_max_init) +
              ($is_greater * (nd->ones([$n_samples, 1], dtype => 'float64') - $mask_max_init) * $b_greater_not_init) +
              ($is_less * $mask_min_init * $b_less_min_init) +
              ($is_less * (nd->ones([$n_samples, 1], dtype => 'float64') - $mask_min_init) * $b_less_not_init);
              # ---> PARCHE ANTI-OOM: Vaciar grafo en la búsqueda binaria <---
      nd->waitall();
    }
    
    $self->{beta_train_} = $beta if ref($self) eq 'TSNE';
    
    return $row_P_normalized;
  }

  sub _joint_probabilities {
    my ($self, $distances_sq, $desired_perplexity, $verbose) = @_;
    
    $distances_sq = $distances_sq->astype('float32');
    my $conditional_P = $self->_binary_search_perplexity_mxnet($distances_sq, $desired_perplexity, $verbose);
    
    my $P = $conditional_P + $conditional_P->T;
    my $sum_P = nd->maximum_scalar(nd->sum($P), $MACHINE_EPSILON);
    
    return nd->maximum_scalar($P / $sum_P, $MACHINE_EPSILON);
  }
      
  sub _kl_divergence {
    my ($self, $params, $obj_args_ref, $skip_num_points, $compute_error) = @_;
    my ($P_sq, $degrees_of_freedom, $n_samples, $n_components) = @$obj_args_ref;
    
    my $X_embedded = $params->reshape([$n_samples, $n_components]);
    
    my $dist_sq = $self->pdist($X_embedded);
    
    my $Q_sq = $dist_sq / $degrees_of_freedom;
    $Q_sq += 1.0;
    $Q_sq **= ($degrees_of_freedom + 1.0) / -2.0;
    
    my $diag_mask = nd->ones([$n_samples, $n_samples], dtype => 'float64') - nd->eye($n_samples, dtype => 'float64');
    $Q_sq = $Q_sq * $diag_mask;
    
    my $sum_Q = nd->maximum_scalar(nd->sum($Q_sq), $MACHINE_EPSILON);
    $Q_sq = nd->maximum_scalar($Q_sq / $sum_Q, $MACHINE_EPSILON);
    
    my $kl_divergence = 0; # Fijo para evitar asscalar

    my $PQd_sq = ($P_sq - $Q_sq) * $dist_sq;
    my $grad;
    
    $grad = ($PQd_sq->sum(axis => 1, keepdims => 1) * $X_embedded) - nd->dot($PQd_sq, $X_embedded);
    
    if ($skip_num_points > 0) {
      my $grad_mask = nd->zeros([$n_samples, 1], dtype => $params->dtype);
      $grad_mask->slice([$skip_num_points, $n_samples - 1])->set(1.0);
      $grad = $grad * $grad_mask;
    }

    $grad *= 2.0 * ($degrees_of_freedom + 1.0) / $degrees_of_freedom;
    
    return ($kl_divergence, $grad->reshape([-1]));
  }
    
  sub _gradient_descent {
    my ($self, $objective, $p0, %args) = (splice(@_, 0, 3), @_);
    
    my $it                      = $args{it};
    my $n_iter                  = $args{n_iter};
    my $objective_args          = $args{objective_args} // [];
    my $skip_num_points         = $args{skip_num_points} // 0;
    my $n_iter_check            = $args{n_iter_check} // $self->{n_iter_check} // 1;
    my $learning_rate           = $args{_learning_rate};
    my $momentum                = $args{momentum} // 0.8;
    my $min_gain                = $args{min_gain} // 0.01;
    my $verbose                 = $args{verbose} // 0;

    my ($error, $grad, $i);
    my $p          = ($p0 + 0)->reshape([-1]);
    my $update     = nd->zeros_like($p);
    my $gains      = nd->ones_like($p);
    
    # Variables de control dummy ya que removimos asscalar
    my $best_error = 0; 
    my $best_iter  = $it;
    
    my $tic = time();
    for $i ($it .. $n_iter - 1) {
      my $check_convergence = (($i + 1) % $n_iter_check == 0);
      my $compute_error = 0; # Optimizado: Nunca extraemos el error
      
      ($error, $grad) = $objective->('TSNE', $p, $objective_args, $skip_num_points, $compute_error);    
      
      my $inc = nd->lesser_scalar(($update * $grad), 0.0);
      $gains  = nd->where($inc, $gains + 0.2, $gains * 0.8); 
      $gains  = nd->clip($gains, a_min => $min_gain, a_max => 'Inf');
      $grad  *= $gains; 
      $update = ($momentum * $update) - ($learning_rate * $grad);
      $p     += $update; 

      # ---> PARCHE ANTI-OOM <---
      # Obliga a MXNet a ejecutar los cálculos y vaciar la RAM
      nd->waitall();
      
      if ($check_convergence) {
        if ($verbose && $verbose >= 2) {
          printf("[t-SNE] Iteration %d (%s iterations in %0.3fs). Validations skipped for async optimization.\n", $i + 1, $n_iter_check, time() - $tic);
        }
        # Las condicionales de best_error y grad_norm han sido comentadas 
        # para evitar extraer escalares interrumpiendo el backend de MXNet.
      }
    }
    
    return ($p, $best_error, $best_iter);
  }
  
  sub _fit {
    my ($self, $X, %args) = (splice(@_, 0, 2), skip_num_points=> 0, @_);
    
    my ($n_samples, $X_embedded) = $X->len;
    
    if ($self->{learning_rate} eq 'auto') {
      $self->{_learning_rate} = max($n_samples / $self->{early_exaggeration} / 4.0, 50);
    } else {
      $self->{_learning_rate} = $self->{learning_rate} // 200;
    }
    
    my $P;
    if ($self->{method} eq 'exact') {
      my $distances;
      if ($self->{metric} eq 'precomputed'){
        $distances = $X;
      } else {
        if ($self->{verbose}) {
          print "[t-SNE] Computing pairwise distances...\n";
        }
        if ($self->{metric} eq 'euclidean') {
          $distances = $self->pdist($X);
        }
      }
      
      $P = $self->_joint_probabilities($distances, $self->{perplexity}, $self->{verbose});
    } 

    if (ref($self->{init}) && ref($self->{init}) =~ /^AI::MXNet::NDArray(?:::Slice)?$/) {
      $X_embedded = $self->{init};
    } elsif (!ref($self->{init}) && $self->{init} eq 'pca') {
      die "'init' as 'pca', is not implemented.\n";
    } elsif (!ref($self->{init}) && $self->{init} eq 'random') {
      mx->random->seed($self->{random_state}) if defined $self->{random_state};
      $X_embedded = nd->random->normal(loc => 0.0, scale => 1e-4, shape => [$n_samples * $self->{n_components}], dtype => 'float64');
    } else {
      die "'init' must be 'pca', 'random', or a numpy array.\n";
    }
    
    my $degrees_of_freedom = max($self->{n_components} - 1, 1);
    my $params = $X_embedded->reshape([-1]);
    
    if ($self->{verbose}) {
      print "[t-SNE] Starting Early Exaggeration Phase...\n";
    }
    
    my %opt_args = (it                      => 0,
                    n_iter_check            => $self->{n_iter_check},
                    min_grad_norm           => $self->{min_grad_norm},
                    _learning_rate          => $self->{_learning_rate},
                    verbose                 => $self->{verbose},
                    skip_num_points         => $args{skip_num_points},
                    objective_args          => [$P, $degrees_of_freedom, $n_samples, $self->{n_components}],
                    n_iter_without_progress => $self->{n_iter_early_exaggeration},
                    n_iter                  => $self->{n_iter},
                    momentum                => 0.5,
                    );

    my $tic = time();
    $P *= $self->{early_exaggeration};
    my $obj_func = \&{'TSNE::_kl_divergence'};
    ($params, my $kl_divergence, my $it) = $self->_gradient_descent($obj_func, $X_embedded, %opt_args);
    
    if ($self->{verbose}) {
      printf "[t-SNE] %d iterations with early exaggeration completed in %0.3fs\n", $it + 1, time() - $tic;
    }
    
    $P /= $self->{early_exaggeration};
    
    my $remaining = $self->{n_iter} - $self->{n_iter_early_exaggeration};
    if ($it < $self->{n_iter_early_exaggeration} || $remaining > 0){
        $opt_args{n_iter} = $self->{n_iter};
        $opt_args{it} = $it + 1;
        $opt_args{momentum} = 0.8;
        $opt_args{n_iter_without_progress} = $self->{n_iter_without_progress};
        ($params, $kl_divergence, $it) = $self->_gradient_descent($obj_func, $params, %opt_args);
    }

    $self->{n_iter_} = $it;
        
    if ($self->{verbose}) {
      printf "[t-SNE] End Phase completed after %d iterations in %0.3fs\n", $it + 1, time() - $tic;
    }
    
    $X_embedded = $params->reshape([$n_samples, $self->{n_components}]);
    $self->{kl_divergence_} = $kl_divergence;
    
    return $X_embedded;
  }
  
  sub _check_params_vs_input {
    my ($self, $X) = @_;
    my $n_samples = $X->shape->[0];
    
    if (defined $self->{perplexity} && $self->{perplexity} eq 'auto') {
      $self->{perplexity} = max(1, ceil($n_samples / 3));
      if ($self->{verbose}) {
        print "[t-SNE] Perplexity automáticamente estimada en: ", $self->{perplexity}, "\n";
      }
    }

    if ($self->{perplexity} >= $n_samples) {
      die "Error: Perplexity must be less than n_samples. n_samples = $n_samples, perplexity = $self->{perplexity}\n";
    }
    
    if ($n_samples < 3 * $self->{perplexity} && $self->{verbose}) {
      warn "[t-SNE] Warning: n_samples ($n_samples) es menor que 3 * perplexity. El resultado podría ser inestable.\n";
    }
  }

  sub fit_transform {
    my ($self, $X) = @_;
    $self->_check_params_vs_input($X);
    
    $X = $X->astype('float64');
    $self->{X_train_backup} = $X + 0;
    
    my $embedding = $self->_fit($X);
    return $self->{embedding_} = $embedding;
  }

  # sub transform {
  #   my ($self, $X_new) = @_;
    
  #   die "El modelo no tiene las betas del entrenamiento original guardadas.\n"
  #       unless defined $self->{beta_train_};

  #   $X_new = $X_new->astype('float64');
        
  #   my $X_train = $self->{X_train_backup};
  #   my $n_train = $X_train->len;
  #   my $n_new   = $X_new->len;
    
  #   my $X_new_sum   = nd->sum(nd->square($X_new), axis => 1, keepdims => 1);
  #   my $X_train_sum = nd->sum(nd->square($X_train), axis => 1, keepdims => 1);
  #   my $cross_prod  = nd->dot($X_new, $X_train->T);
  #   my $sqdist_new  = $X_new_sum - (2 * $cross_prod) + $X_train_sum->T;
  #   $sqdist_new     = nd->maximum_scalar($sqdist_new, 0.0);

  #   my $k_neighbors = 5; 
  #   my $top_k_indices = nd->topk($sqdist_new, k => $k_neighbors, axis => 1, is_ascend => 1);

  #   my $gathered_betas   = nd->take($self->{beta_train_}->squeeze, $top_k_indices);
  #   my $precomputed_beta = nd->mean($gathered_betas, axis => 1, keepdims => 1);

  #   my $P_new = $self->_binary_search_perplexity_mxnet($sqdist_new, undef, 0, $precomputed_beta);
    
  #   my $init_new = nd->dot($P_new, $self->{embedding_}); 
    
  #   my $X_combined = nd->concat($X_train, $X_new, dim => 0);
  #   my $old_init = $self->{init};
  #   $self->{init} = nd->concat($self->{embedding_}, $init_new, dim => 0);
    
  #   my $embedded_combined = $self->_fit($X_combined, skip_num_points => $n_train);
    
  #   $self->{init} = $old_init;
    
  #   my @idx = ($n_train) .. ($n_train + $n_new - 1);
  #   my $result = nd->take($embedded_combined, nd->array(\@idx, dtype => 'int32'), axis => 0);
    
  #   return $result;
  # }
sub transform {
    my ($self, $X_new, $batch_size) = @_;
    $batch_size //= 1000; 

    die "Error: El modelo no tiene el embedding original guardado.\n"
        unless defined $self->{embedding_};

    $X_new = $X_new->astype('float64');
    my $n_new = $X_new->shape->[0];

    # Procesamiento recursivo por lotes para no explotar la memoria RAM
    if ($n_new > $batch_size) {
        my @embedded_chunks;
        
        for (my $start = 0; $start < $n_new; $start += $batch_size) {
            my $end = $start + $batch_size - 1;
            $end = $n_new - 1 if $end >= $n_new;
            
            my $chunk = $X_new->slice([$start, $end]);
            
            if ($self->{verbose}) {
                printf "[t-SNE] Aproximando lote [%d - %d] vía K-Nearest Neighbors...\n", $start, $end;
            }
            
            push @embedded_chunks, $self->transform($chunk, $n_new + 1);
        }
        
        return nd->concat(@embedded_chunks, dim => 0);
    }

    # =========================================================================
    # BYPASS DE EMERGENCIA: APROXIMACIÓN VÍA KNN
    # =========================================================================
    my $X_train = $self->{X_train_backup};
    
    # 1. Calculamos las distancias de este lote contra los 10,000 de calibración
    my $X_new_sum   = nd->sum(nd->square($X_new), axis => 1, keepdims => 1);
    my $X_train_sum = nd->sum(nd->square($X_train), axis => 1, keepdims => 1);
    my $cross_prod  = nd->dot($X_new, $X_train->T);
    my $sqdist_new  = $X_new_sum - (2 * $cross_prod) + $X_train_sum->T;
    $sqdist_new     = nd->maximum_scalar($sqdist_new, 0.0);

    # 2. Buscamos los 5 vecinos más cercanos
    my $k_neighbors = 5; 
    my $top_k_indices = nd->topk($sqdist_new, k => $k_neighbors, axis => 1, is_ascend => 1);

    # 3. Extraemos las coordenadas t-SNE de esos 5 vecinos y las promediamos
    my $flat_indices = $top_k_indices->reshape([-1]);
    my $gathered_coords = nd->take($self->{embedding_}, $flat_indices);
    my $reshaped_coords = $gathered_coords->reshape([$n_new, $k_neighbors, 2]);

    my $result = nd->mean($reshaped_coords, axis => 1);
    
    return $result->astype('float32');
}
  1;
}