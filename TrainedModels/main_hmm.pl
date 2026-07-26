#!/usr/bin/perl
use strict;
use warnings;
use Text::CSV;
use AI::MXNet qw(mx nd);

# 1. Ajuste de ruta: Apuntamos a la carpeta Market/ML donde está el HMM.pm de Dome
use lib '/home/erick/Documents/TradeViewReplica/Market/ML';
require 'HMM.pm'; 

$| = 1;

sub procesar_archivo {
    my ($archivo_entrada, $archivo_salida, $modelo_hmm, $es_entrenamiento) = @_;
    print "-> Leyendo $archivo_entrada...\n";
    
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    open my $fh_in, "<:encoding(utf8)", $archivo_entrada or die $!;
    
    my $header = $csv->getline($fh_in);
    
    my (@filas_completas, @clusters);
    my $idx_cluster = -1;
    for my $i (0 .. $#$header) { $idx_cluster = $i if $header->[$i] eq 'cluster_gmm'; }
    die "No se encontró la columna 'cluster_gmm'" if $idx_cluster == -1;

    while (my $row = $csv->getline($fh_in)) {
        push @filas_completas, $row;
        push @clusters, int($row->[$idx_cluster]);
    }
    close $fh_in;

    if ($es_entrenamiento) {
        print "   -> Entrenando Matrices HMM...\n";
        $modelo_hmm->fit(\@clusters);
    }

    print "   -> Ejecutando Viterbi...\n";
    my $estados_ocultos = $modelo_hmm->predict(\@clusters);
    my $estados_arr = $estados_ocultos->asarray;

    print "   -> Exportando $archivo_salida...\n";
    push @$header, 'estado_oculto';
    open my $fh_out, ">:encoding(utf8)", $archivo_salida or die $!;
    $csv->print($fh_out, $header);
    
    for my $i (0 .. $#filas_completas) {
        my $fila = $filas_completas[$i];
        push @$fila, $estados_arr->[$i];
        $csv->print($fh_out, $fila);
    }
    close $fh_out;
    print "   [OK] Completado.\n\n";
}

print "--- INICIANDO FASE 2: HMM VITERBI ---\n";
my $hmm = Market::ML::HMM->new(num_states => 3, smoothing => 1.0, emission_accuracy => 0.85);

# 2. Ajuste de ruta: Leemos los archivos fase 1 desde TrainedModels y los guardamos en la raíz
procesar_archivo('/home/erick/Documents/TradeViewReplica/TrainedModels/train_fase1.csv', '/home/erick/Documents/TradeViewReplica/train_listo_para_lstm.csv', $hmm, 1);
procesar_archivo('/home/erick/Documents/TradeViewReplica/TrainedModels/test_fase1.csv', '/home/erick/Documents/TradeViewReplica/test_listo_para_lstm.csv', $hmm, 0);

print "=======================================================\n";
print "¡TODOS LOS DATOS ESTÁN LISTOS PARA LA RED NEURONAL!\n";
print "=======================================================\n";