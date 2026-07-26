#!/usr/bin/perl
use strict;
use warnings;
use Data::Dump qw(dump);
use AI::MXNet qw(mx nd);
use Text::CSV;
use FindBin qw($Bin);

# Importar tus librerías locales
use sml;
use lib $Bin;
use TSNE; # Asegúrate de que TSNE.pm esté en el mismo directorio
require "$Bin/GMM.pl";

$| = 1;

# =========================================================================
# 1. FUNCIONES AUXILIARES
# =========================================================================
sub load_dataset {
    my ($filename) = @_;
    print "-> Cargando dataset desde '$filename'...\n";
    
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    open my $fh, "<:encoding(utf8)", $filename or die "No se pudo abrir $filename: $!";
    
    my $header = $csv->getline($fh);
    
    for my $col (@$header) {
        $col =~ s/^\x{FEFF}//;
        $col =~ s/^\s+|\s+$//g;
        $col = lc($col);
    }
    
    my %data;
    $data{$_} = [] for @$header;
    
    while (my $row = $csv->getline($fh)) {
        for my $i (0 .. $#$header) {
            my $val = (defined $row->[$i] && $row->[$i] ne '') ? $row->[$i] : 0;
            push @{$data{$header->[$i]}}, $val;
        }
    }
    close $fh;
    
    my $num_rows = scalar(@{$data{$header->[0]}});
    print "   [OK] Dataset cargado: $num_rows filas obtenidas.\n";
    return \%data;
}

sub exportar_fase1 {
    my ($archivo, $tsne_tensor, $clusters_tensor, $data_hash) = @_;
    
    open my $fh, ">:encoding(utf8)", $archivo or die "No se pudo crear $archivo: $!";
    my $csv = Text::CSV->new({ binary => 1, eol => "\n" });
    
    my @cabeceras = ('tsne_1', 'tsne_2', 'cluster_gmm', 'pivote3', 'pivote5', 'pivote10', 'pivote15');
    $csv->print($fh, \@cabeceras);
    
    my $tsne_arr    = $tsne_tensor->asarray;
    my $cluster_arr = $clusters_tensor->asarray;
    my $num_rows    = $tsne_tensor->shape->[0];
    
    for my $i (0 .. $num_rows - 1) {
        my @fila = (
            $tsne_arr->[$i][0],
            $tsne_arr->[$i][1],
            $cluster_arr->[$i],
            $data_hash->{'pivote3'}->[$i]  // 0,
            $data_hash->{'pivote5'}->[$i]  // 0,
            $data_hash->{'pivote10'}->[$i] // 0,
            $data_hash->{'pivote15'}->[$i] // 0
        );
        $csv->print($fh, \@fila);
    }
    close $fh;
    print "      -> $archivo generado exitosamente ($num_rows filas).\n";
}

# =========================================================================
# FLUJO PRINCIPAL
# =========================================================================

# $Bin apunta automáticamente a:
# TradeViewReplica/TrainedModels
#
# Por eso "$Bin/.." corresponde a:
# TradeViewReplica

my $train_file = "$Bin/../training.csv";
my $test_file  = "$Bin/../test.csv";

print "[1/6] Cargando archivos fuente...\n";
my $train_hash = load_dataset($train_file);
my $test_hash  = load_dataset($test_file);
print "\n";

# Cambia $MODO_PRUEBA a 0 para ejecutar el pipeline con TODOS los datos.
my $MODO_PRUEBA = 0; 
my $FILAS_PRUEBA = 500; # sino mi pc explota jajaja 

if ($MODO_PRUEBA) {
    print "-> [MODO PRUEBA ACTIVADO] Reduciendo datasets a $FILAS_PRUEBA filas...\n\n";
    
    # Recortar el hash de entrenamiento
    for my $col (keys %$train_hash) {
        # Evitamos errores si el archivo tiene menos filas que $FILAS_PRUEBA
        my $max_idx = $FILAS_PRUEBA - 1;
        $max_idx = $#{$train_hash->{$col}} if $max_idx > $#{$train_hash->{$col}};
        @{$train_hash->{$col}} = @{$train_hash->{$col}}[0 .. $max_idx];
    }
    
    # Recortar el hash de pruebas
    for my $col (keys %$test_hash) {
        my $max_idx = $FILAS_PRUEBA - 1;
        $max_idx = $#{$test_hash->{$col}} if $max_idx > $#{$test_hash->{$col}};
        @{$test_hash->{$col}} = @{$test_hash->{$col}}[0 .. $max_idx];
    }
}

# -------------------------------------------------------------------------
# 2. PRE-PROCESAMIENTO DEL CONJUNTO DE ENTRENAMIENTO
# -------------------------------------------------------------------------
print "[2/6] Preparando Train Matrix (Ensamblado y Poda)...\n";
my ($X_train_full, $train_feature_names) = sml->build_feature_matrix($train_hash);
my ($X_train_gmm, $gmm_names)            = sml->select_gmm_columns($X_train_full, $train_feature_names);
my ($X_train, $pruned_names)             = sml->prune_correlated_features($X_train_gmm, $gmm_names, threshold => 0.90);
print "\n";

# -------------------------------------------------------------------------
# 3. ALINEACIÓN DEL CONJUNTO DE PRUEBAS
# -------------------------------------------------------------------------
print "[3/6] Ensamblando y alineando Test Matrix...\n";
my ($X_test_full, $test_feature_names) = sml->build_feature_matrix($test_hash);

# Crear un mapa para encontrar rápido los índices de las columnas en test
my %test_col_idx;
@test_col_idx{@$test_feature_names} = (0 .. $#$test_feature_names);

my $num_test_rows = $X_test_full->shape->[0];
my $num_pruned_cols = scalar(@$pruned_names);

# Extracción vectorizada de un solo golpe (¡Adiós al problema del slice!)
my @keep_idx_in_test;
for my $col_name (@$pruned_names) {
    if (exists $test_col_idx{$col_name}) {
        push @keep_idx_in_test, $test_col_idx{$col_name};
    } else {
        die "Error fatal: La columna '$col_name' requerida por GMM no existe en test.csv\n";
    }
}
# nd->take extrae todas las columnas correctas simultáneamente
my $X_test = nd->take($X_test_full, nd->array(\@keep_idx_in_test), axis => 1);
printf "      -> Matriz de test alineada: %d filas x %d columnas\n\n", $X_test->shape->[0], $X_test->shape->[1];

print "      -> Estandarizando (Z-score) características...\n";
# Calcular media y desviación estándar usando SOLO el set de entrenamiento
my $mean = nd->mean($X_train, axis => 0, keepdims => 1);
my $std  = nd->sqrt(nd->mean(nd->square($X_train - $mean), axis => 0, keepdims => 1) + 1e-8);

# Escalar Train
$X_train = ($X_train - $mean) / $std;

# Escalar Test (usando los parámetros de Train para evitar data leakage)
$X_test = ($X_test - $mean) / $std;

# -------------------------------------------------------------------------
# 4. REDUCCIÓN DE DIMENSIONALIDAD CON t-SNE
# -------------------------------------------------------------------------
# print "[4/6] Ejecutando t-SNE...\n";
# my $tsne = TSNE->new(
#     n_components  => 2,
#     perplexity    => 30.0,
#     learning_rate => 'auto',
#     max_iter      => 250,
#     verbose       => 1
# );

# print "      -> fit_transform en Train...\n";
# my $X_train_tsne = $tsne->fit_transform($X_train);

# print "      -> transform en Test...\n";
# my $X_test_tsne = $tsne->transform($X_test);
# print "\n";
print "[4/6] Ejecutando t-SNE...\n";
my $tsne = TSNE->new(
    n_components  => 2,
    perplexity    => 30.0,
    learning_rate => 'auto',
    max_iter      => 50, #el profe utiliza 250 iteraciones, pero pa q no explote le pongo 50
    verbose       => 1
);

# Definimos un límite seguro para evitar desbordar el límite de 32 bits de MXNet
my $total_train = $X_train->shape->[0];

# Sample size se debe cambiar a un valor adecuado (por ejemplo 15000)
my $sample_size = 10000; 
$sample_size = $total_train if $sample_size > $total_train;

print "      -> Calibrando espacio t-SNE en submuestra de Train ($sample_size filas)...\n";

my @idx = ($total_train - $sample_size) .. ($total_train - 1);
my $indices = nd->array(\@idx, dtype => 'int32');
# my $X_train_sample_raw = nd->take($X_train, $indices, axis => 0);
# my $X_train_sample = nd->array($X_train_sample_raw->asarray, dtype => 'float64');

# Usa esto:
my $X_train_sample = nd->take($X_train, $indices, axis => 0)->astype('float64');

printf "      -> DEBUG shape sample: %d x %d\n", $X_train_sample->shape->[0], $X_train_sample->shape->[1];
print "Antes del transform\n";
$tsne->fit_transform($X_train_sample);
print "Después del transform\n";

print "      -> Proyectando la totalidad del dataset Train ($total_train filas)...\n";
# Transform usa multiplicación matricial asimétrica (88k x 15k = 1.33 billones), 
# lo que es menor al límite de 2.14 billones de MXNet. ¡Cabrá en memoria!
my $X_train_tsne = $tsne->transform($X_train)->astype('float32');

print "      -> Proyectando matriz de Test...\n";
my $X_test_tsne = $tsne->transform($X_test)->astype('float32');
print "\n";

# -------------------------------------------------------------------------
# 5. ENTRENAMIENTO E INFERENCIA GMM (Sobre t-SNE)
# -------------------------------------------------------------------------
print "[5/6] Optimizando GMM sobre componentes t-SNE...\n";
my ($best_k, $best_model, $all_results) = sml->select_k_by_bic(
    $X_train_tsne,
    k_range     => [3, 4, 5, 6, 7], 
    max_iter    => 150,             
    tol         => 1e-4,            
    init_params => 'random_from_data'
);

printf "      -> GMM encontró K = %d regímenes óptimos.\n", $best_k;

# Extracción para Train
my $train_clusters = nd->argmax($best_model->{resp}, axis => 1);


# Inferencia para Test
my $test_clusters;
if (sml->can('gmm_predict')) {
    $test_clusters = sml->gmm_predict($best_model, $X_test_tsne);
} else {
    warn "ADVERTENCIA: No se encontró método gmm_predict(). Asignando ceros temporalmente a Test.\n";
    $test_clusters = nd->zeros([$X_test_tsne->shape->[0]], dtype => 'int32');
}
print "\n";

# -------------------------------------------------------------------------
# 6. EXPORTACIÓN DE ARCHIVOS FASE 1
# -------------------------------------------------------------------------
print "[6/6] Exportando resultados...\n";
exportar_fase1('train_fase1.csv', $X_train_tsne, $train_clusters, $train_hash);
exportar_fase1('test_fase1.csv',  $X_test_tsne,  $test_clusters,  $test_hash);

print "\n=======================================================\n";
print "PIPELINE FASE 1 COMPLETADO EXITOSAMENTE\n";
print "=======================================================\n";