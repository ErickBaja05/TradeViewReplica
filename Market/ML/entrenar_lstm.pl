use strict;
use warnings;
use AI::MXNet qw(mx nd);
use Text::CSV;
use List::Util qw(zip);
use FindBin qw($Bin);

# Agregamos la raíz y TrainedModels a las rutas de búsqueda de Perl
use lib "$Bin/../.."; 
use lib "$Bin/../../TrainedModels";

use sml qw(show_plot);

# 1. Cargamos la taxonomía usando la ruta absoluta calculada
require "$Bin/../../TrainedModels/GMM.pl";

print "--- Iniciando Pipeline Predictivo LSTM (FUSIÓN DE DATOS) ---\n";

# 2. FUNCIÓN DE CARGA SEGURA PARA DATOS CRUDOS
sub load_raw_csv {
    my ($filename) = @_;
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    open my $fh, "<:encoding(utf8)", $filename or die $!;
    my $header = $csv->getline($fh);
    for my $col (@$header) { $col =~ s/^\x{FEFF}//; $col =~ s/^\s+|\s+$//g; $col = lc($col); }
    my %data; $data{$_} = [] for @$header;
    while (my $row = $csv->getline($fh)) {
        for my $i (0 .. $#$header) {
            my $val = (defined $row->[$i] && $row->[$i] ne '') ? $row->[$i] : 0;
            push @{$data{$header->[$i]}}, $val;
        }
    }
    close $fh;
    return \%data;
}

print "-> 1/4 Recuperando datos originales del mercado...\n";
my $train_hash = load_raw_csv("training.csv");
my $test_hash  = load_raw_csv("test.csv");

my ($X_train_orig, $names_train) = sml->build_feature_matrix($train_hash);
my ($X_test_orig,  $names_test)  = sml->build_feature_matrix($test_hash);

# Alineamos las columnas del testeo con las del entrenamiento original
my %test_col_idx; @test_col_idx{@$names_test} = (0 .. $#$names_test);
my @keep_idx;
for my $col (@$names_train) { 
    push @keep_idx, $test_col_idx{$col} if exists $test_col_idx{$col}; 
}
my $X_test_orig_aligned = nd->take($X_test_orig, nd->array(\@keep_idx), axis => 1);

print "-> 2/4 Cargando inteligencia artificial (TSNE + GMM + HMM)...\n";
my ($train_fase2, $h_train) = sml->load_csv("train_listo_para_lstm.csv");
my ($test_fase2,  $h_test)  = sml->load_csv("test_listo_para_lstm.csv");

my $tf2    = nd->array($train_fase2);
my $testf2 = nd->array($test_fase2);

# Extraemos las variables de IA: tsne_1(0), tsne_2(1), cluster_gmm(2), estado_oculto(7)
my $idx_extra     = nd->array([0, 1, 2, 7]);
my $X_train_extra = nd->take($tf2, $idx_extra, axis=>1);
my $X_test_extra  = nd->take($testf2, $idx_extra, axis=>1);

# Extraemos los targets: pivote3(3), pivote5(4), pivote10(5), pivote15(6)
my $idx_targets = nd->array([3, 4, 5, 6]);
my $y_train     = nd->take($tf2, $idx_targets, axis=>1);
my $y_test      = nd->take($testf2, $idx_targets, axis=>1);

print "-> 3/4 Realizando la Gran Fusión de Tensores...\n";

# =========================================================
# PARCHE ANTI-TRAMPA (DATA LEAKAGE)
# Quitamos las respuestas (pivotes) de los datos originales
# =========================================================
my @target_names = ('pivote3', 'pivote5', 'pivote10', 'pivote15');
my @safe_feature_idx;
for my $i (0 .. $#$names_train) {
    my $col = $names_train->[$i];
    push @safe_feature_idx, $i unless grep { $_ eq $col } @target_names;
}

my $safe_idx_nd = nd->array(\@safe_feature_idx);
my $X_train_clean = nd->take($X_train_orig, $safe_idx_nd, axis => 1);
my $X_test_clean  = nd->take($X_test_orig_aligned, $safe_idx_nd, axis => 1);

# Ahora sí juntamos los datos limpios con la inteligencia extraída
my $X_train = nd->concat($X_train_clean, $X_train_extra, dim=>1);
my $X_test  = nd->concat($X_test_clean, $X_test_extra, dim=>1);

# Estandarización robusta de la nueva súper-matriz
my $all_data = nd->concat($X_train, $X_test, dim=>0);
my $X_means  = nd->mean($all_data, axis=>0);
my $X_stdevs = nd->std($all_data, axis=>0, ddof=>1) + 1e-8;

$X_train = nd->broadcast_div(nd->broadcast_sub($X_train, $X_means), $X_stdevs);
$X_test  = nd->broadcast_div(nd->broadcast_sub($X_test,  $X_means), $X_stdevs);

print "-> 4/4 Generando secuencias temporales para LSTM...\n";
sub make_sequences {
    my ($X, $y, $seq_len) = @_;
    my $N      = $X->len;
    my $base   = nd->arange($N-$seq_len+1)->reshape([-1, 1]);
    my $offset = nd->arange($seq_len)->reshape([1, -1]);
    my $idx    = $base + $offset;
    my $X_seq  = nd->take($X,$idx);
    my $y_seq  = $y->slice([$seq_len-1, $N])->sever;
    return ($X_seq, $y_seq);
}

my $seq_len = 10;
my ($X_train_seq, $y_train_seq) = make_sequences($X_train, $y_train, $seq_len);
my ($X_test_seq,  $y_test_seq)  = make_sequences($X_test,  $y_test,  $seq_len);

my $batch_size = 128;
sub load_array{
    my ($data_arrays, $batch_size, %args) = (splice (@_, 0, 2), is_train => 1, last_batch => 'keep', @_);
    my ($X, $y) = @$data_arrays;
    my $dataset = mx->gluon->data->ArrayDataset(data => $X, label => $y);
    return mx->gluon->data->DataLoader($dataset, batch_size => $batch_size, shuffle => $args{is_train}, last_batch => $args{last_batch} // 'discard');
}
my $train_iter = load_array([$X_train_seq, $y_train_seq], $batch_size, is_train => 1, last_batch => 'rollover');
my $test_iter  = load_array([$X_test_seq,  $y_test_seq],  $batch_size, is_train => 0, last_batch => 'keep');

package PredictorLSTM {
    use AI::MXNet qw(mx);
    use base ("AI::MXNet::Gluon::Block");
    sub new{
        my ($class, %args) = @_;
        my $self = $class->SUPER::new(%args);                                  
        $self->{lstm} = mx->gluon->rnn->LSTM(
            hidden_size   => $args{hidden_units}, 
            num_layers    => $args{num_layer} // 1,
            layout        => 'NTC',
            dropout       => $args{dropout} // 0.2
        );
        $self->{dense} = mx->gluon->nn->Dense(units => $args{units}, in_units => $args{in_units}, activation => 'sigmoid');
        map{$self->register_child($self->{$_})} ('lstm', 'dense');
        return bless($self, $class);
    }
    sub forward {
        my ($self, $X) = @_;
        my $H = $self->{lstm}->forward($X);
        my $seq_len = $X->shape->[1];
        $H = $H->slice(':', [$seq_len - 1, $seq_len], ':')->reshape([0, -1]);
        return $self->{dense}->forward($H);
    }
    1;
}

# 4 targets (pivotes)
my $net = new PredictorLSTM(hidden_units => 32, num_layer => 2, dropout => 0.2, units => 4, in_units => 32);
$net->collect_params->initialize(init => mx->init->Xavier(), force_reinit => 1);

# =========================================================================
# BLOQUE DE ENTRENAMIENTO COMENTADO (Para no sobreescribir los pesos)
# =========================================================================
# my $lr = 0.005; 
# my $loss = mx->gluon->loss->L2Loss(); 
# my $trainer = mx->gluon->Trainer($net->collect_params(), optimizer => 'adam', optimizer_params=>{ learning_rate => $lr });
# 
# my $num_epochs = 20; 
# print "Iniciando entrenamiento por $num_epochs épocas...\n";
# for (my $epoch = 0; $epoch < $num_epochs; $epoch++){
#     my $inicio_epoca = time();
#     while ( my $batch = <$train_iter> ) {
#         my ($X, $y) = @$batch;
#         my $l;
#         mx->autograd->record(sub {
#             my $y_hat = $net->($X);
#             $l = $loss->($y_hat, $y->astype('float32'));
#         });
#         $l->backward();
#         $trainer->step($X->len);
#     }
#     nd->waitall(); 
#     my $tiempo_epoca = time() - $inicio_epoca;
#     print "Época " . ($epoch + 1) . " completada en $tiempo_epoca segundos.\n";
# }
# 
# mkdir 'TrainedModels' unless -d 'TrainedModels';
# my $model_file_name = 'TrainedModels/lstm_weights.mdl';
# $net->save_parameters($model_file_name);
# print "\n¡Modelo entrenado y pesos guardados en $model_file_name!\n";
# =========================================================================

# 7. CARGA DEL MODELO (SIN ENTRENAR)
my $model_file_name = 'TrainedModels/lstm_weights.mdl';
die "Error: No se encontró el modelo entrenado en $model_file_name\n" unless -e $model_file_name;

print "\n-> Cargando pesos pre-entrenados desde $model_file_name...\n";
$net->load_parameters($model_file_name);
print "   [OK] Memoria de la red restaurada exitosamente.\n\n";

print "-> 5/5 Evaluando conjunto de testeo...\n";
my (@logits, $X_t, $y_t);
while(my $batch = <$test_iter>){
    ($X_t, $y_t) = @$batch;
    push @logits, $net->forward($X_t);
}
my $preds = nd->concat(@logits, dim=>0);

# 10. MÉTRICAS CONTINUAS (Cálculo Nativo)
my $mae_val  = nd->mean(nd->abs($preds - $y_test_seq))->asscalar;
my $rmse_val = sqrt(nd->mean(nd->square($preds - $y_test_seq))->asscalar);

print "\n--- RESULTADOS GENERALES ---\n";
printf "Error Absoluto Medio (MAE): %.4f\n", $mae_val;
printf "Raíz Error Cuadrático Medio (RMSE): %.4f\n", $rmse_val;

## 11. MATRIZ DE CONFUSIÓN Y CURVA ROC (MULTI-HORIZONTE)
print "\n===================================================\n";
print "ANÁLISIS DE PREDICCIÓN MULTI-HORIZONTE\n";
print "===================================================\n";

my @nombres_ventanas = ('3 Minutos', '5 Minutos', '10 Minutos', '15 Minutos');
my @traces_master;

# Añadimos la línea diagonal de referencia a la gráfica maestra
my $trace_ref_master = new Chart::Plotly::Trace::Scatter(x => [0, 1], y => [0, 1], mode => 'lines', name => 'Azar (Referencia)', line => {dash => 'dash'});
push @traces_master, $trace_ref_master;

for my $columna_analisis (0 .. 3) {
    print "\n---> EVALUANDO VENTANA DE $nombres_ventanas[$columna_analisis] <---\n";
    
    my $y_test_bin = ($y_test_seq->slice(':', $columna_analisis) > 0.5)->astype('int8');
    my $preds_bin  = ($preds->slice(':', $columna_analisis) > 0.5)->astype('int8');

    my ($clases, $matrix) = sml->confusion_matrix($y_test_bin, $preds_bin);
    print "Matriz de Confusión:\n" . $matrix->asstr . "\n";

    my $accuracy = sml->accuracy_metric($y_test_bin, $preds_bin);
    printf "Exactitud (Accuracy): %0.2f%%\n", $accuracy;

    # Cálculo para la curva ROC de esta ventana
    my $positive_probs = $preds->slice(':', $columna_analisis);
    my $thresholds = nd->arange(101) / 100;

    my ($fprs_array, $tprs_array) = (List::Util::zip map { 
        my ($f, $t) = sml->perf_metrics($y_test_bin, $positive_probs, $_, positive_class => 1);
        [$f, $t];
    } @$thresholds);

    my $fprs = nd->concat(@$fprs_array, dim=>0);
    my $tprs = nd->concat(@$tprs_array, dim=>0);
    my $sorted_indices = nd->argsort($fprs, axis=>0);
    my $sorted_fprs = nd->take($fprs, $sorted_indices);
    my $sorted_tprs = nd->take($tprs, $sorted_indices);

    my $auc = sml->trapz($sorted_fprs, $sorted_tprs);
    printf "Área bajo la curva (AUC): %0.2f\n", $auc;
    
    # 1. CREAMOS LA CURVA PARA LA VENTANA ACTUAL
    my $trace_roc = new Chart::Plotly::Trace::Scatter(
        x => $sorted_fprs->aspdl, 
        y => $sorted_tprs->aspdl, 
        mode => 'lines', 
        name => "$nombres_ventanas[$columna_analisis] (AUC: $auc)"
    );
    
    # 2. GENERAMOS Y MOSTRAMOS LA GRÁFICA INDIVIDUAL
    my $trace_ref_indiv = new Chart::Plotly::Trace::Scatter(x => [0, 1], y => [0, 1], mode => 'lines', name => 'Azar (Referencia)', line => {dash => 'dash'});
    my $plot_indiv = new Chart::Plotly::Plot(
      traces => [$trace_roc, $trace_ref_indiv],
      layout => { 
          title => "Curva ROC - Predicción $nombres_ventanas[$columna_analisis]", 
          xaxis => { title => 'Tasa de Falsos Positivos (FPR)' }, 
          yaxis => { title => 'Tasa de Verdaderos Positivos (TPR)' }
      }
    );
    show_plot($plot_indiv);

    # 3. GUARDAMOS LA LÍNEA PARA LA GRÁFICA MAESTRA FINAL
    push @traces_master, $trace_roc;
}

# 4. GENERAMOS Y MOSTRAMOS LA GRÁFICA MAESTRA (LAS 4 CURVAS JUNTAS)
my $plot_master = new Chart::Plotly::Plot(
  traces => \@traces_master,
  layout => { 
      title => 'Curvas ROC - Predicción Multi-Horizonte (LSTM)', 
      xaxis => { title => 'Tasa de Falsos Positivos (FPR)' }, 
      yaxis => { title => 'Tasa de Verdaderos Positivos (TPR)' }
  }
);
show_plot($plot_master);

print "\n===================================================\n";
print "¡PIPELINE COMPLETADO! Revisa tu navegador para ver las 5 gráficas.\n";
print "===================================================\n";