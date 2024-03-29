#!/bin/bash
#
#SBATCH --ntasks=1
#SBATCH --qos=normal --time=10:00:00
#SBATCH --exclusive
#
#This recomend to minimize clashes with other users
#SBATCH --partition=scaling
#report email setup
#SBATCH --mail-user kaarthik@lanl.gov
#SBATCH --mail-type=FAIL

srun julia -t 25 --project=. src/main.jl "$@"