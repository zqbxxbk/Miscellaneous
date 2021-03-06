#include <stdio.h>
#include <math.h>
#include <iostream>

#include <thrust\device_vector.h>
#include <thrust\transform_reduce.h>
#include <thrust\reduce.h>
#include <thrust\tuple.h>

#include "BBComplex.h"
#include "InputOutput.cuh"
#include "Utilities.cuh"
#include "Matlab_like.cuh"
#include "Polynomials.cuh"
#include "Synthesis.cuh"
#include "NFFT2_2D.cuh"
#include "NDFT2_2D.cuh"

#define pi 3.141592653589793238463

// --- Algorithm parameters
#define freq				((14.25)*(1e9))					// Operating frequency 
#define lambda				((3e8)/(freq))                  // Wavelength
#define beta				((2.*pi)/(lambda))              // Wavenumber

#define M_x					11                              // Number of reflectarray elements along the x-axis
#define M_y					11                              // Number of reflectarray elements along the y-axis

#define dx					((0.5)*(lambda))                // dist elem x (per array)
#define dy					((0.5)*(lambda))                // dist elem y (per array)

#define aap					(((M_x)-(1))*((dx)/(2)))        // Reflectarray semi-dimension along the x-axis
#define bap					(((M_y)-(1)))*((dy)/(2))        // Reflectarray semi-dimension along the y-axis

#define mfact				12                              // Feed pattern: cos^mfact(theta)

// ??? INUTILI ???
#define dmin				((0.51)*(lambda))               // Minimum allowed inter-element spacing
#define dmax				((0.7 )*(lambda))               // Maximum allowed inter-element spacing

#define dmin_x				((0.51)*(lambda))               // Minimum allowed inter-element spacing along the x-axis
#define dmin_y				((0.51)*(lambda))               // Minimum allowed inter-element spacing along the y-axis
#define dmax_x				((0.7 )*(lambda))               // Maximum allowed inter-element spacing along the x-axis
#define dmax_y				((0.7 )*(lambda))               // Maximum allowed inter-element spacing along the y-axis

#define z0					((2)*(0.8)*(sqrt((aap)*(aap)+(bap)*(bap))))
															// Focal length of the reflectarray surface

#define feed_center_x		0.								
#define feed_center_y		((1.15)*(bap))
#define feed_center_z		(-z0)

#define alfa				(-atan((feed_center_y)/(feed_center_z)))            
															// Feed illumination angle

#define Num_unknowns_x		5								// Number of unknowns for the element positions along the x-axis
#define Num_unknowns_y		5								// Number of unknowns for the element positions along the y-axis

#define Num_unknowns_phases	6								// Number of unknowns for the phase representation

#define chi_u_prime			4                               // Spectral oversampling factor along u
#define chi_v_prime			4                               // Spectral oversampling factor along v

#define a_prime				((chi_u_prime)*(aap))			
#define b_prime				((chi_v_prime)*(bap))

#define u_max				((beta)/(2.))					// Maximum value of the spectral region along the u axis
#define u_min				(-(beta)/(2.))					// Minimum value of the spectral region along the u axis
#define v_max				((beta)/(2.))					// Maximum value of the spectral region along the v axis
#define v_min				(-(beta)/(2.))					// Minimum value of the spectral region along the v axis

#define DEBUG

/********/
/* MAIN */
/********/
int main()
{
	cublasHandle_t handle; cublasSafeCall(cublasCreate(&handle));
	
	// --- Defining spectral quantities
	int Nu, Nv;
	thrust::pair<thrust::pair<float *, float *>, float *> d_SpectralTuple = defineSpectralQuantities((float)u_max, (float)v_max, (float)a_prime, (float)b_prime, (float)beta, &Nu, &Nv);
	thrust::pair<float *, float *> d_UV_discrete = d_SpectralTuple.first;
	float *d_U_discrete = d_UV_discrete.first;
	float *d_V_discrete = d_UV_discrete.second;
	float *d_Filter		= d_SpectralTuple.second;

	saveGPUrealtxt(d_U_discrete,	"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\U_discrete.txt", (2 * Nu) * (2 * Nv));
	saveGPUrealtxt(d_V_discrete,	"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\V_discrete.txt", (2 * Nu) * (2 * Nv));
	saveGPUrealtxt(d_Filter,		"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\d_Filter.txt",   (2 * Nu) * (2 * Nv));

	// --- Generating the (csi, eta) grid and the Legendre polynomials
	thrust::pair<thrust::pair<float *, float *>, float *> d_LegendreTuple = generateLegendreFactorized<float>(Num_unknowns_x, Num_unknowns_y, M_x, M_y);
	thrust::pair<float *, float *> d_CSI_ETA = d_LegendreTuple.first;
	float *d_CSI = d_CSI_ETA.first;
	float *d_ETA = d_CSI_ETA.second;
	float *d_LEG = d_LegendreTuple.second;
	
	saveGPUrealtxt(d_CSI,	"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\d_CSI.txt", M_x * M_y);
	saveGPUrealtxt(d_ETA,	"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\d_ETA.txt", M_x * M_y);
	saveGPUrealtxt(d_LEG,	"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\d_LEG.txt", Num_unknowns_x * Num_unknowns_y * M_x * M_y);

	// --- Generating the Zernike polynomials
	float *d_ZERNIKE = generateZernikep(d_CSI, d_ETA, Num_unknowns_phases, M_x, M_y);
	
	saveGPUrealtxt(d_ZERNIKE,	"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\d_ZERNIKE.txt", Num_unknowns_phases * M_x * M_y);

	// --- Loading the masks
	float *d_External_Coverage = loadGPUrealtxt("C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\External_Coverage.txt", d_External_Coverage, (2 * Nu) * (2 * Nv));
	float *d_Internal_Coverage = loadGPUrealtxt("C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\Internal_Coverage.txt", d_Internal_Coverage, (2 * Nu) * (2 * Nv));

	

	/***********/
	/* TESTING */
	/***********/

	// --- Generating Zernike coefficients
	float *h_Coeff_Zernike = (float *)malloc(Num_unknowns_phases * sizeof(float)); 
	h_Coeff_Zernike[0] = -10.;
	h_Coeff_Zernike[1] =  50.;
	h_Coeff_Zernike[2] =   8.;
	h_Coeff_Zernike[3] =   9.;
	h_Coeff_Zernike[4] =   0.;
	h_Coeff_Zernike[5] =   0.;
	float *d_Coeff_Zernike;	gpuErrchk(cudaMalloc(&d_Coeff_Zernike, Num_unknowns_phases * sizeof(float)));
	gpuErrchk(cudaMemcpy(d_Coeff_Zernike, h_Coeff_Zernike, Num_unknowns_phases * sizeof(float), cudaMemcpyHostToDevice));

	// --- Loading Lagrange coefficients
	float *d_Coeff_Lagrange_x = loadGPUrealtxt("C:\\Users\\angelo\\Documents\\Sintesi\\Sintesi_POS_Aperiodic_Reflectarray\\Coeff_legendre_x_init_vett.txt", d_Coeff_Lagrange_x, Num_unknowns_x * Num_unknowns_y);
	float *d_Coeff_Lagrange_y = loadGPUrealtxt("C:\\Users\\angelo\\Documents\\Sintesi\\Sintesi_POS_Aperiodic_Reflectarray\\Coeff_legendre_y_init_vett.txt", d_Coeff_Lagrange_y, Num_unknowns_x * Num_unknowns_y);
	
	// --- Calculate far field
	float2_ *d_far_field = raFarFieldCalculation(d_Coeff_Zernike, d_ZERNIKE, 
											     d_Coeff_Lagrange_x, d_Coeff_Lagrange_y, d_LEG,   
											     d_U_discrete, d_V_discrete,
												 d_Filter,
												 Num_unknowns_phases, Num_unknowns_x, Num_unknowns_y,
												 handle, 
											     feed_center_x, feed_center_y, feed_center_z,
												 alfa, beta, mfact, 
												 a_prime, b_prime,
												 M_x, M_y,
												 Nu, Nv);

	saveGPUcomplextxt(d_far_field,	"C:\\Users\\angelo\\Documents\\CEM\\ParticleSwarm\\ParticleSwarmSynthesis\\ParticleSwarmSynthesisMatlab\\Far_Field_NUFFT.txt", (2 * Nu) * (2 * Nv));

	double Functional = raFunctionalCalculation(d_far_field, d_Internal_Coverage, d_External_Coverage, Nu, Nv);

	printf("Functional = %f\n", Functional);

	return 0;
}
