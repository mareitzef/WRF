#!/bin/bash
#SBATCH --job-name=compile_wrf
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=2G
#SBATCH --time=200

# Load modules and set environment variables
source ~/wrf_dev.sh

# Using the “clean -a” Tool
# It is often necessary to clean the code before recompiling, but not always.
#         The code should be cleaned when modifications have been made to the configure.wrf(wps) file, or any changes have been made to a WRF/Registry/* file. If so, issue ./clean -a prior to recompiling.
#         Modifications to subroutines, or .F and .F90 files, within the code require a recompile, but DO NOT require the code to be cleaned, nor reconfigured before recompiling. Simply recompile, which should be much faster than a clean compile.

# modify configure.wrf. 
# Find the line starting with LDFLAGS_LOCAL = and add
# -Wl,-rpath=$(NETCDF)/lib before the # sign.
# After this you can start the compilation with the compile script. 

# run compile
srun ./compile em_real -j 4 >& log.compile2
# if there are compilation errors use 
# srun ./compile em_real -j 1 2>&1 | tee log.compile


