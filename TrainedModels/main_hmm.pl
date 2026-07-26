#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($Bin);

# $Bin apunta a:
# TradeViewReplica/TrainedModels
#
# La raíz del proyecto está en:
# $Bin/..
use lib "$Bin/..";

use Text::CSV;
use Market::ML::HMM;

$| = 1;

# =========================================================================
# FASE 2 - HMM / VITERBI
#
# ENTRADAS:
#   TrainedModels/train_fase1.csv
#   TrainedModels/test_fase1.csv
#
# SALIDAS:
#   TrainedModels/train_listo_para_lstm.csv
#   TrainedModels/test_listo_para_lstm.csv
#
# IMPORTANTE:
#   - El HMM aprende A, B y pi SOLO usando TRAIN.
#   - TEST utiliza exactamente las mismas matrices aprendidas con TRAIN.
# =========================================================================

my $train_file = "$Bin/train_fase1.csv";
my $test_file  = "$Bin/test_fase1.csv";

my $train_out = "$Bin/train_listo_para_lstm.csv";
my $test_out  = "$Bin/test_listo_para_lstm.csv";


# =========================================================================
# 1. CARGAR CSV
# =========================================================================
sub cargar_csv {
    my ($archivo) = @_;

    print "-> Cargando '$archivo'...\n";

    my $csv = Text::CSV->new({
        binary    => 1,
        auto_diag => 1,
    });

    open my $fh, "<:encoding(utf8)", $archivo
        or die "No se pudo abrir '$archivo': $!\n";

    my $header = $csv->getline($fh)
        or die "El archivo '$archivo' no contiene cabecera.\n";

    # Limpiar nombres de columnas
    for my $col (@$header) {
        $col =~ s/^\x{FEFF}//;
        $col =~ s/^\s+|\s+$//g;
        $col = lc($col);
    }

    my @filas;

    while (my $row = $csv->getline($fh)) {
        push @filas, $row;
    }

    close $fh;

    print "   [OK] " . scalar(@filas) . " filas cargadas.\n";

    return ($header, \@filas);
}


# =========================================================================
# 2. BUSCAR UNA COLUMNA POR NOMBRE
# =========================================================================
sub buscar_indice_columna {
    my ($header, $nombre) = @_;

    for my $i (0 .. $#$header) {
        return $i if lc($header->[$i]) eq lc($nombre);
    }

    die "No se encontro la columna '$nombre'.\n"
      . "Columnas disponibles: "
      . join(", ", @$header)
      . "\n";
}


# =========================================================================
# 3. CONVERTIR NDARRAY DE MXNET A ARRAY PERL
# =========================================================================
sub tensor_a_array {
    my ($tensor) = @_;

    my @resultado;

    for my $i (0 .. $tensor->len - 1) {
        push @resultado,
            int($tensor->slice($i)->asscalar);
    }

    return \@resultado;
}


# =========================================================================
# 4. EXPORTAR CSV CON LA NUEVA COLUMNA estado_oculto
# =========================================================================
sub exportar_con_estado_oculto {
    my ($archivo, $header, $filas, $estados) = @_;

    if (scalar(@$filas) != scalar(@$estados)) {
        die "Error: cantidad de estados ocultos distinta "
          . "a cantidad de filas.\n";
    }

    my $csv = Text::CSV->new({
        binary    => 1,
        auto_diag => 1,
        eol       => "\n",
    });

    open my $fh, ">:encoding(utf8)", $archivo
        or die "No se pudo crear '$archivo': $!\n";

    # Mantener todas las columnas de Josue
    # y agregar estado_oculto al final
    my @header_salida = (
        @$header,
        'estado_oculto'
    );

    $csv->print(
        $fh,
        \@header_salida
    );

    for my $i (0 .. $#$filas) {

        my @fila = (
            @{$filas->[$i]},
            $estados->[$i]
        );

        $csv->print(
            $fh,
            \@fila
        );
    }

    close $fh;

    print "   [OK] '$archivo' generado con "
        . scalar(@$filas)
        . " filas.\n";
}


# =========================================================================
# FLUJO PRINCIPAL
# =========================================================================

print "\n";
print "=======================================================\n";
print "FASE 2 - HMM / VITERBI\n";
print "=======================================================\n\n";


# -------------------------------------------------------------------------
# 1. LEER ARCHIVOS GENERADOS POR t-SNE + GMM
# -------------------------------------------------------------------------
print "[1/5] Cargando resultados de Fase 1...\n";

my ($train_header, $train_rows)
    = cargar_csv($train_file);

my ($test_header, $test_rows)
    = cargar_csv($test_file);

print "\n";


# -------------------------------------------------------------------------
# 2. EXTRAER cluster_gmm
# -------------------------------------------------------------------------
print "[2/5] Extrayendo columna cluster_gmm...\n";

my $idx_train
    = buscar_indice_columna(
        $train_header,
        'cluster_gmm'
    );

my $idx_test
    = buscar_indice_columna(
        $test_header,
        'cluster_gmm'
    );


my @cluster_train = map {
    int($_->[$idx_train])
} @$train_rows;


my @cluster_test = map {
    int($_->[$idx_test])
} @$test_rows;


die "TRAIN no contiene observaciones cluster_gmm.\n"
    unless @cluster_train;

die "TEST no contiene observaciones cluster_gmm.\n"
    unless @cluster_test;


print "   [OK] TRAIN: "
    . scalar(@cluster_train)
    . " observaciones.\n";

print "   [OK] TEST : "
    . scalar(@cluster_test)
    . " observaciones.\n";

print "\n";


# -------------------------------------------------------------------------
# 3. DETERMINAR NUMERO DE ESTADOS
#
# Se calcula SOLO a partir de TRAIN.
# Si GMM genero clusters 0,1,2,3 entonces:
#
# num_states = 4
# -------------------------------------------------------------------------

my $max_cluster = 0;

for my $cluster (@cluster_train) {

    die "cluster_gmm invalido en TRAIN: $cluster\n"
        if $cluster < 0;

    $max_cluster = $cluster
        if $cluster > $max_cluster;
}

my $num_states = $max_cluster + 1;


print "[3/5] Entrenando HMM SOLO con TRAIN...\n";

print "   -> Numero de estados detectado: "
    . $num_states
    . "\n";


# -------------------------------------------------------------------------
# CREAR HMM
# -------------------------------------------------------------------------

my $hmm = Market::ML::HMM->new(

    num_states => $num_states,

    # Suavizado Laplace para evitar probabilidades cero
    smoothing => 1.0,

    # Probabilidad asumida de que el cluster observado
    # corresponda al estado oculto
    emission_confidence => 0.80,
);


# -------------------------------------------------------------------------
# ENTRENAMIENTO
#
# AQUI se calculan:
#
# pi = probabilidades iniciales
# A  = matriz de transicion
# B  = matriz de emisiones
#
# IMPORTANTE:
# Solo se utiliza TRAIN.
# -------------------------------------------------------------------------

$hmm->fit(
    \@cluster_train
);

print "   [OK] HMM entrenado.\n";

print "\n";


# -------------------------------------------------------------------------
# 4. VITERBI SOBRE TRAIN Y TEST
# -------------------------------------------------------------------------

print "[4/5] Ejecutando Viterbi...\n";


# TRAIN
print "   -> Procesando TRAIN...\n";

my $estado_train_tensor
    = $hmm->predict(
        \@cluster_train
    );


# TEST
#
# NO se llama fit() nuevamente.
# Se utilizan las mismas matrices:
#
# A
# B
# pi
#
# aprendidas con TRAIN.
print "   -> Procesando TEST usando las mismas "
    . "matrices A, B y pi...\n";

my $estado_test_tensor
    = $hmm->predict(
        \@cluster_test
    );


# Convertir NDArray a array Perl
my $estado_train
    = tensor_a_array(
        $estado_train_tensor
    );

my $estado_test
    = tensor_a_array(
        $estado_test_tensor
    );


print "   [OK] Secuencias ocultas calculadas.\n";

print "\n";


# -------------------------------------------------------------------------
# MOSTRAR MUESTRA TRAIN
# -------------------------------------------------------------------------

print "Primeras observaciones TRAIN:\n";

printf "%-8s %-14s %-14s\n",
    "fila",
    "cluster_gmm",
    "estado_oculto";

print "-" x 40;
print "\n";


my $muestra_train
    = @cluster_train < 20
    ? scalar(@cluster_train)
    : 20;


for my $i (0 .. $muestra_train - 1) {

    printf "%-8d %-14d %-14d\n",
        $i,
        $cluster_train[$i],
        $estado_train->[$i];
}


print "\n";


# -------------------------------------------------------------------------
# MOSTRAR MUESTRA TEST
# -------------------------------------------------------------------------

print "Primeras observaciones TEST:\n";

printf "%-8s %-14s %-14s\n",
    "fila",
    "cluster_gmm",
    "estado_oculto";

print "-" x 40;
print "\n";


my $muestra_test
    = @cluster_test < 20
    ? scalar(@cluster_test)
    : 20;


for my $i (0 .. $muestra_test - 1) {

    printf "%-8d %-14d %-14d\n",
        $i,
        $cluster_test[$i],
        $estado_test->[$i];
}


print "\n";


# -------------------------------------------------------------------------
# 5. EXPORTAR ARCHIVOS PARA LA LSTM
# -------------------------------------------------------------------------

print "[5/5] Exportando archivos finales...\n";


exportar_con_estado_oculto(
    $train_out,
    $train_header,
    $train_rows,
    $estado_train
);


exportar_con_estado_oculto(
    $test_out,
    $test_header,
    $test_rows,
    $estado_test
);


print "\n";

print "=======================================================\n";
print "FASE HMM COMPLETADA EXITOSAMENTE\n";
print "=======================================================\n";


print "\nArchivos generados:\n";

print "  -> TrainedModels/train_listo_para_lstm.csv\n";
print "  -> TrainedModels/test_listo_para_lstm.csv\n";


print "\nLos archivos conservan las columnas de Fase 1:\n";

print "  tsne_1\n";
print "  tsne_2\n";
print "  cluster_gmm\n";
print "  pivote3\n";
print "  pivote5\n";
print "  pivote10\n";
print "  pivote15\n";

print "\ny agregan:\n";

print "  estado_oculto\n";


print "\nEl HMM fue entrenado solamente con TRAIN.\n";
print "TEST fue procesado utilizando las mismas matrices "
    . "A, B y pi.\n\n";