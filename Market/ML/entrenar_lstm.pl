use strict;
use warnings;
use Data::Dump qw(dump);
use List::Util qw(zip);
use AI::MXNet qw(mx nd);
use sml qw(show_plot);

print "--- Iniciando Pipeline Predictivo LSTM (Modo Blindado) ---\n";

# 1. CARGA DE DATOS DESDE LA RAÍZ DEL PROYECTO
# Ejecutar desde la raíz usando: perl Market/ML/entrenar_lstm.pl
my $train_file_name = "train_listo_para_lstm.csv";
my $test_file_name  = "test_listo_para_lstm.csv"; 

die "Error: No se encuentra $train_file_name en la raíz.\n" unless -e $train_file_name;
die "Error: No se encuentra $test_file_name en la raíz.\n" unless -e $test_file_name;

my ($train_data, $train_header) = sml->load_csv($train_file_name);
my ($test_data,  $test_header)  = sml->load_csv($test_file_name);

my $train = nd->array($train_data);
my $test  = nd->array($test_data);

# 2. SEPARACIÓN ROBUSTA (Anti-fallos humanos)
my @target_names = ('pivote3', 'pivote5', 'pivote10', 'pivote15');
my @ignore_names = ('minute', 'hour', 'day', 'month', 'year'); # Columnas a ignorar
my (@target_indices, @feature_indices);

for my $i (0 .. $#$train_header) {
    my $col_name = $train_header->[$i];
    
    if (grep { $_ eq $col_name } @target_names) {
        push @target_indices, $i;
    } elsif (grep { $_ eq $col_name } @ignore_names) {
        # Si Josué olvidó borrar las fechas, las ignoramos silenciosamente
        next;
    } else {
        push @feature_indices, $i;
    }
}

my $idx_features = nd->array(\@feature_indices);
my $idx_targets  = nd->array(\@target_indices);

my $X_train = nd->take($train, $idx_features, axis => 1);
my $X_test  = nd->take($test,  $idx_features, axis => 1);

my $y_train = nd->take($train, $idx_targets, axis => 1);
my $y_test  = nd->take($test,  $idx_targets, axis => 1);

# 3. ESTANDARIZACIÓN
my $all_data = nd->concat($X_train, $X_test, dim=>0);
my $X_means  = nd->mean($all_data, axis=>0);
my $X_stdevs = nd->std($all_data, axis=>0, ddof=>1);

sml->standardize_dataset($X_train, $X_means, $X_stdevs);
sml->standardize_dataset($X_test,  $X_means, $X_stdevs);

# 4. GENERACIÓN DE SECUENCIAS
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

# 5. ITERADORES
my $batch_size = 128;
sub load_array{
  my ($data_arrays, $batch_size, %args) = (splice (@_, 0, 2), is_train => 1, last_batch => 'keep', @_);
  my ($X, $y) = @$data_arrays;
  my $dataset = mx->gluon->data->ArrayDataset(data => $X, label => $y);
  return mx->gluon->data->DataLoader($dataset, batch_size => $batch_size, shuffle => $args{is_train}, last_batch => $args{last_batch} // 'discard');
}
my $train_iter = load_array([$X_train_seq, $y_train_seq], $batch_size, is_train => 1, last_batch => 'rollover');
my $test_iter  = load_array([$X_test_seq,  $y_test_seq],  $batch_size, is_train => 0, last_batch => 'keep');

# 6. ARQUITECTURA LSTM
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
    $self->{dense} = mx->gluon->nn->Dense(units => $args{units}, in_units => $args{in_units});
    map{$self->register_child($self->{$_})} ('lstm', 'dense');
    return bless($self, $class);
  }
  sub forward {
    my ($self, $X) = @_;
    my $H = $self->{lstm}->forward($X);
    $H = $H->slice(':', -1, ':')->sever; 
    return $self->{dense}->forward($H);
  }
  1;
}

my $net = new PredictorLSTM(hidden_units => 32, num_layer => 2, dropout => 0.2, units => scalar(@target_names), in_units => 32);
$net->collect_params->initialize(init => mx->init->Xavier(), force_reinit => 1);

# 7. ENTRENAMIENTO
my $lr = 0.005;
my $loss = mx->gluon->loss->L2Loss(); 
my $trainer = mx->gluon->Trainer($net->collect_params(), optimizer => 'adam', optimizer_params=>{ learning_rate => $lr });

my $num_epochs = 20; 
print "Iniciando entrenamiento por $num_epochs épocas...\n";
for (my $epoch = 0; $epoch < $num_epochs; $epoch++){
  while ( my $batch = <$train_iter> ) {
    my ($X, $y) = @$batch;
    my $l;
    mx->autograd->record(sub {
      my $y_hat = $net->($X);
      $l = $loss->($y_hat, $y->astype('float32'));
    });
    $l->backward();
    $trainer->step($X->len);
  }
  print "Época " . ($epoch + 1) . " completada.\n";
}

# 8. GUARDADO DEL MODELO
mkdir 'TrainedModels' unless -d 'TrainedModels';
my $model_file_name = 'TrainedModels/lstm_weights.mdl';
$net->save_parameters($model_file_name);
print "\n¡Modelo entrenado y pesos guardados en $model_file_name!\n";

# 9. PREDICCIONES DE TESTEO
my (@logits, $X_t, $y_t);
while(my $batch = <$test_iter>){
  ($X_t, $y_t) = @$batch;
  push @logits, $net->forward($X_t);
}
my $preds = nd->concat(@logits, dim=>0);

# 10. MÉTRICAS CONTINUAS
my $mae  = sml->mae_metric($y_test_seq, $preds);
my $rmse = sml->rmse_metric($y_test_seq, $preds);
print "\n--- RESULTADOS GENERALES ---\n";
print "Error Absoluto Medio (MAE): $mae\n";
print "Raíz Error Cuadrático Medio (RMSE): $rmse\n";

# 11. MATRIZ DE CONFUSIÓN Y CURVA ROC
my $columna_analisis = 0; 

my $y_test_bin = ($y_test_seq->slice(':', $columna_analisis) > 0.5)->astype('int8');
my $preds_bin  = ($preds->slice(':', $columna_analisis) > 0.5)->astype('int8');

my ($clases, $matrix) = sml->confusion_matrix($y_test_bin, $preds_bin);
print "\nMatriz de Confusión (Alta prob. de rastros en Ventana 3 min):\n" . $matrix->asstr . "\n";

my $accuracy = sml->accuracy_metric($y_test_bin, $preds_bin);
printf "Exactitud (Accuracy): %0.2f%%\n", $accuracy;

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

my $trace1 = new Chart::Plotly::Trace::Scatter(x => $sorted_fprs->aspdl, y => $sorted_tprs->aspdl, mode => 'lines', name => "ROC Curve (AUC: $auc)");
my $trace2 = new Chart::Plotly::Trace::Scatter(x => [0, 1], y => [0, 1], mode => 'lines', name => 'Referencia');

my $plot = new Chart::Plotly::Plot(
  traces => [$trace1, $trace2],
  layout => { title => 'Curva ROC - Predicción Ventana 3 Minutos', xaxis => { title => 'False Positive Rate (FPR)' }, yaxis => { title => 'True Positive Rate (TPR)' }}
);
show_plot($plot);