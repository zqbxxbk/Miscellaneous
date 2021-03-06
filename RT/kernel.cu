// --- Things to fix:

// --- RT is float-based, while many parts of SVD are double-based.
// --- There are some pattern assignments (see setAntennas) which are useless
// --- Check that everything runs on 1 gpus.
// --- Check that everything runs on 0 gpus.
// --- Insert timing
// --- How inserting include directories directly in c++ files, instead as Visual Studio options
// --- Add diffraction ?
// --- Check the channel capacity. Are the results correct? For 12 tx antennas and 4 rx the result is 500
// --- It does not work with more Legendre polynomials
// --- There is no point in using the code for num_TX > num_RX because the matrices must be vertical
//     rectangular. There is a known bug for num_TX = 4 and num_RX = 6 in project_on_curve in the for
//     loop managing the calculation of legendre coefficients.
#include <cuda.h>
#include <cuda_runtime.h>

#include <omp.h>

#include <iostream>
#include <iomanip>
#include <vector>
#include <algorithm>

#include <thrust\device_vector.h>
#include <thrust\random\linear_congruential_engine.h>
#include <thrust\random\uniform_real_distribution.h>
#include <thrust\random\uniform_int_distribution.h>

#include "vec3.h"
#include "setAntennas.h"
#include "pattern.h"
#include "utils.h"
#include "RXTX.h"
#include "load_nbin.h"
#include "edge.h"
#include "device_path_finder.h"
#include "host_path_finder.h"
#include "ray_path.h"
#include "trace_path.h"
#include "svd.h"
//
#include "optimizerAncillary.cuh"
#include "Scattering_Matrix.cuh"
#include "svd.cuh"
#include "MIMO.cuh"
#include "Utilities.cuh"

#include "TimingCPU.h"
#include "TimingGPU.cuh"

//std::string meshFileName		= "D:\\Project\\FindPaths5\\FindPaths4\\plate_and_cylinder_MIMO.nbin";
std::string meshFileName		= "D:\\Project\\FindPaths5\\FindPaths4\\plate_and_cylinder_rectangular_MIMO.nbin";
std::string edgeListFileName    = "D:\\Project\\FindPaths5\\FindPaths4\\edge_list_v2.ssv";
std::string txPatternFileName	= "D:\\Project\\FindPaths5\\FindPaths4\\pattern_completo_simmetrico.pat";
std::string rxPatternFileName	= "D:\\Project\\FindPaths5\\FindPaths4\\pattern_completo_simmetrico.pat";

nvmesh mesh;
bool mesh_loaded = false;
std::vector<TX> txs;
std::vector<RX> rxs;

std::vector<path> global_path_list;
        
thrust::minstd_rand rng_main(time(NULL));

/********/
/* MAIN */
/********/
int main(int argc, char** argv) {
    
	/*****************************/
	/* DIFFERENTIAL EVOLUTIONARY */
    /*****************************/
	const int			Npop		= 4;							// --- Number of population members 
	//const int			Npop		= 1;							// --- Number of groups 
    const int			Nconf		= 4;							// --- Number of TX/RX antenna configurations per population member
																	//     (TX antennas are fixed per population member)
    const int			gen_max		= 1;							// --- Maximum number of generations
    const float			CR			= 0.4;							// --- Crossover coefficient for the differential evolutionary algorithm
    const float			F			= 0.7;							// --- Amplification coefficient for the differential evolutionary algorithm
	bool				final_iter	= false;

	/********************/
	/* ELECTROMAGNETICS */
	/********************/
	const double		lambda		= 0.125;						// --- Wavelength

	/************/
	/* ANTENNAS */
	/************/
	const int				num_TX		= 4;						// --- Number of transmitting antennas
	const int				num_RX		= 4;						// --- Number of receiving antennas

	std::vector<vec3>		azr_tx(num_TX);							// --- [Azimuth Zenith Roll] for the transmitting antennas
    std::vector<vec3>		azr_rx(num_RX);							// --- [Azimuth Zenith Roll] for the receiving antennas

	vec3					origintx;								// --- Transmitting antenna segment origin
    vec3					originrx;								// --- Receiving antenna segment origin

	segment					TXline;									// --- Transmitters line
	segment					RXline;									// --- Receivers line

	txs.resize(num_TX);												// --- Transmitter positions			
    rxs.resize(num_RX * Nconf);										// --- Receiver positions

	std::vector<pattern *>   pattern_list;							// --- Patterns (for use of ray tracer)
	std::vector<std::string> pattern_tx;							// --- Patterns for the transmitting antennas (for use of optimizer)
    std::vector<std::string> pattern_rx;							// --- Patterns for the receiving antennas (for use of optimizer)

    thrust::host_vector<vec3> best_pos_tx(num_TX);					// --- Best TX positions generated by the optimizer
    thrust::host_vector<vec3> best_pos_rx(num_RX);					// --- Best RX positions generated by the optimizer
    thrust::host_vector<vec3> best_h_rx(num_RX);
    thrust::host_vector<vec3> best_h_tx(num_TX);   

	TX						tx;										// --- Temporary transmitter location
	RX						rx;										// --- Temporary receiver location

	// --- Plate
	//origintx.x	= -3.; origintx.y	=  0.; origintx.z	=  4.;
	//originrx.x	=  3.; originrx.y	=  0.; originrx.z	=  4.;

	// --- Cylinder
	//origintx.x	= 0.; origintx.y	=  -10.; origintx.z	=  0.;
	//originrx.x	= 0.; originrx.y	=   10.; originrx.z	=  0.;

	// --- Cylinder + plate
	origintx.x	= 15. * lambda; origintx.y	=  -40. * lambda; origintx.z	=  0.;
	originrx.x	= 15. * lambda; originrx.y	=   40. * lambda; originrx.z	=  0.;

	// --- Plate
	//vec3 dtx;														// --- Transmitting antenna segment orientation
	//dtx.x		=  1.; dtx.y		=  0.;	dtx.z		=  0.;

	//vec3 drx;														// --- Receiving antenna segment orientation
	//drx.x		=  1.;	drx.y		=  0.;	drx.z		=  0.;

	// --- Cylinder and plate
	vec3 dtx;														// --- Transmitting antenna segment orientation
	dtx.x		=  1.; dtx.y		=  0.;	dtx.z		=  0.;

	vec3 drx;														// --- Receiving antenna segment orientation
	drx.x		=  1.;	drx.y		=  0.;	drx.z		=  0.;

	const float radius = 0.1;										// --- Radius of the detector

	setAntennas(&TXline, &RXline, origintx, originrx, azr_tx, azr_rx, &tx, &rx, pattern_tx, pattern_rx, dtx, drx, radius, txPatternFileName, rxPatternFileName, num_TX, num_RX);

    /*********************************************/
	/* REPRESENTATION OF TX/RX ANTENNA POSITIONS */
    /*********************************************/
    const int			NTXCoeff	= 3;							// --- Number of expansion coefficients for the transmitting antennas
    const int			NRXCoeff	= 3;							// --- Number of expansion coefficients for the transmitting antennas

	double step_tx;													// --- Transmitting antenna polynomial sampling steps
    double step_rx;													// --- Receiving antenna polynomial sampling steps

	std::vector<double> xsi_tx(num_TX);								// --- Transmitting antenna polynomial sampling points
    std::vector<double> xsi_rx(num_RX);								// --- Receiving antenna polynomial sampling points

	std::vector<vec3> pos_tx(num_TX * Npop);							// --- Transmitting antenna positions, num_TX per group 
    std::vector<vec3> pos_rx(num_RX * Npop * Nconf);						// --- Receiving antenna positions, Nconf * num_RX per group

    std::vector<double> LegendreCoeffTX(num_TX * NTXCoeff);			// --- Legendre coefficients for the transmitting antennas
    std::vector<double> LegendreCoeffRX(num_RX * NRXCoeff);			// --- Legendre coefficients for the receiving antennas

    std::vector<group> parent_pop(Npop);								// --- Current population
    std::vector<group> child_pop(Npop);								// --- Population updated after each iteration
        
	thrust::uniform_int_distribution<int> dist_pop(0, Npop - 1);		// --- Random generator for the group indices
    thrust::uniform_int_distribution<int> dist_group(0, Nconf - 1);	// --- Random generator for the group elements
    thrust::uniform_real_distribution<float> randb(0, 1);			// --- Random generator for crossover evaluation

    uint ind_max_group	 = 0;										
    uint ind_max_element = 0;   

	/***********/
	/* CHANNEL */
	/***********/
    const double		SNR_linear	= 200;						// --- Signal to Noise Ratio
	
    thrust::host_vector<double>   host_matrix((2 * num_RX * Npop * Nconf) * 2 * num_TX, 0.);	// --- Host array of the channel matrices
    thrust::host_vector<double>	  C_h(Npop * Nconf, 0.);									// --- Host array of the channel capacities for all configurations
    thrust::host_vector<double>   Cg_h(Npop);											// --- Host array of the channel capacities per group (best per group)
    
    thrust::device_vector<double> device_matrix((2 * num_RX * Npop * Nconf)* 2 * num_TX, 0.);// --- Device array of the channel matrices
	thrust::device_vector<double> C_d(Npop * Nconf);									// --- Device array of the channel capacities for all configurations
    thrust::device_vector<double> Cg_d(Npop);											// --- Device array of the channel capacities per group (best per group)
      
	/*******/
	/* SVD */
	/*******/
	const bool use_device = 0;														// --- SVD Computation: 0 --> CPU 1 --> GPU    
    thrust::host_vector<double>   singular_values_h(Npop * Nconf * num_TX);				// --- Host array of the singular values
    thrust::device_vector<double> singular_values_d(Npop * Nconf * num_TX);				// --- Device array of the singular values

    // --- Allocating device resources for svd calculation
    svd_plan<double> plan;
    create_plan(plan, 2 * num_RX, 2 * num_TX, Npop * Nconf); 
   
	/*************/
	/* MAIN CODE */
	/*************/
	int numCPU = omp_get_num_procs();
	int numGPU;  gpuErrchk(cudaGetDeviceCount(&numGPU));
	//int numGPU = 0;

    std::cout << "Number of host CPUs: "    << numCPU << std::endl;
    std::cout << "Number of CUDA devices: " << numGPU << std::endl;
    
    // --- Loading the mesh
	std::cout << "Loading mesh...\n";
    load_model_nbin(meshFileName, mesh);
	mesh_loaded = true;

	// --- Loading the edge list
    std::vector<edge> edge_list;
	load_edge_list(edgeListFileName, mesh.faces.size(), edge_list);
    std::cout << "Loading edge list...\n";
    //for(size_t i = 0; i < edge_list.size(); i++) std::cerr << edge_list[i] << std::endl;
    
    // --- Initialize scattering matrix
	std::vector<cfloat> H((num_RX * Nconf) * num_TX);
    for(size_t i = 0; i < (num_RX * Nconf) * num_TX; i++) H[i] = make_cfloat(0.f, 0.f);

    size_t max_cnt   = 20;
	        
	//// --- Transmitter #1
	////tx.pos.x		= 5.f;	
	//tx.pos.x		= 2.f;	
	////tx.pos.y		= 1.f;	
	//tx.pos.y		= 0.f;	
	//tx.pos.z		= 4.f;	
	pattern_list.push_back(tx.patt);
	//tx.update_unit_vectors();
	//txs.push_back(tx); 

	//// --- Receiver #1 
	////rx.pos.x		= -5.f;	
	//rx.pos.x		= -.5f;	
	//rx.pos.y		= 0.f;	
	//rx.pos.z		= 5.f;	
	rx.update_unit_vectors();
	//rxs.push_back(rx);
	//
	//// --- Receiver #2 
	////rx.pos.x		= -3.f;	
	//rx.pos.x		= -1.f;	
	//rx.pos.y		= 0.f;	
	//rx.pos.z		= 3.f;	
	//rx.update_unit_vectors();
	//rxs.push_back(rx);

	std::vector<pathfinder_p> pathfinder_list;
	for (size_t i = 0; i < numGPU; i++) 
		pathfinder_list.push_back(device_create_path_finder(i, mesh.verts, mesh.faces, mesh.normals_and_k1, mesh.x1_and_k2, mesh.remapping_table, 
															mesh.N0, mesh.N1, mesh.N2, mesh.N3, mesh.bb, max_cnt));
    
    for (size_t i = 0; i < numCPU; i++) 
        pathfinder_list.push_back(host_create_path_finder(mesh.verts, mesh.faces, mesh.normals_and_k1, mesh.x1_and_k2, mesh.remapping_table, mesh.N0,
														  mesh.N1, mesh.N2, mesh.N3, mesh.bb, edge_list));

    gpuErrchk(cudaSetDevice(0));
	
	// --- Population initialization
	init_groups(parent_pop, num_TX, NTXCoeff, num_RX, NRXCoeff, Nconf, rx.radius, TXline, RXline, azr_tx, azr_rx, pattern_tx, pattern_rx, step_tx, step_rx,
                xsi_tx, xsi_rx, LegendreCoeffTX, LegendreCoeffRX);
                
    std::cerr << "Antenna positions optimizer for MIMO applications\n" << std::endl;
    std::cerr << "Number of groups :" << Npop << "\n Number of elements per group :" << Nconf << " num_RX:" << num_RX << " num_TX:" << num_TX << std::endl;
    if(use_device == 1) std::cerr << "Using GPU" << std::endl;
    else				std::cerr << "Using CPU" << std::endl;

    //build_positions(parent_pop, pos_tx, pos_rx, LegendreCoeffTX, LegendreCoeffRX);          
    build_positions_with_constraints(parent_pop, pos_tx, pos_rx, xsi_tx, xsi_rx, lambda, step_tx, step_rx,  LegendreCoeffTX, LegendreCoeffRX);

	/*********************************/
	/* SCATTERING MATRIX CALCULATION */
	/*********************************/
	txs.clear();
	rxs.clear();
    for (uint i = 0; i < Npop ; i++) {

		// --- Transmitting antennas
		for (uint j = 0; j < num_TX; j++) { 
			tx.pos.x		= pos_tx[j + i * num_TX].x;	
			tx.pos.y		= pos_tx[j + i * num_TX].y;	
			tx.pos.z		= pos_tx[j + i * num_TX].z;	
			tx.azimuth		= deg2rad(0.f);
			tx.zenith		= deg2rad(0.f);
			tx.roll			= deg2rad(0.f);
			tx.update_unit_vectors();

			txs.push_back(tx); 
		}
		
		// --- Receiving antennas
		for (uint k = 0; k < Nconf; k++) {
	    
			for(uint j = 0; j < num_RX; j++) {
				rx.pos.x		= pos_rx[j + k * num_RX + i * Nconf * num_RX].x;	
				rx.pos.y		= pos_rx[j + k * num_RX + i * Nconf * num_RX].y;	
				rx.pos.z		= pos_rx[j + k * num_RX + i * Nconf * num_RX].z;	
				rx.azimuth		= deg2rad(0.f);
				rx.zenith 		= deg2rad(0.f);
				rx.roll			= deg2rad(0.f);
				rx.update_unit_vectors();
				rxs.push_back(rx);
				//printf("%f %f %f %f\n", rx.pos.x, rx.pos.y, rx.pos.z, rx.radius);
			}        	    
		}	    

		// --- H is a num_RX * Nconf x num_TX matrix - row-major - it has num_RX * Nconf rows and num_TX columns
		computeScatteringMatrix(argc, argv, numCPU, numGPU, max_cnt, pathfinder_list, mesh, edge_list, global_path_list, num_TX, num_RX * Nconf, 
			                    txs, rxs, lambda, H, final_iter);

		//std::cout << "#num TX  num RX" << std::endl;
		//std::cout << num_TX << " " << num_RX * Nconf << std::endl;
		//for (size_t r = 0; r < num_RX * Nconf; r++) {
		//	for (size_t c = 0; c < num_TX; c++) {
		//		std::cout << REAL(H[c + r * num_TX]) << " " << IMAG(H[c + r * num_TX]) << " ";  
		//	}
		//	std::cout << std::endl;
		//}
		//printf("\n\n");

		//std::cout << H[0].x << " " << H[0].y << "\n";
		//for (int p = 0; p < num_RX * Nconf * num_TX; p++) std::cout << H[p].x << " " << H[p].y << "\n";
		
        uint dim = i * (2 * num_TX) * (2 * num_RX * Nconf);
        for (uint r = 0; r < 2 * num_RX * Nconf; r++) {
            for (uint c = 0; c < 2 * num_TX; ++c) {       
      
                // --- Upper-left quadrant
				if(c < num_TX && r < num_RX * Nconf)   host_matrix[dim + c * (2 * num_RX * Nconf) + r] =  H[r                 * num_TX + c           ].x;     
                 
                // --- Upper-right quadrant
                if(c >= num_TX && r < num_RX * Nconf)  host_matrix[dim + c * (2 * num_RX * Nconf) + r] = -H[r                 * num_TX + (c - num_TX)].y;    
                    
                // --- Lower-left quadrant
				if(c < num_TX && r >= num_RX * Nconf)  host_matrix[dim + c * (2 * num_RX * Nconf) + r] =  H[(r - num_RX * Nconf) * num_TX + c].y;    
                    
                // --- Lower-right quadrant
				if(c >= num_TX && r >= num_RX * Nconf) host_matrix[dim + c * (2 * num_RX * Nconf) + r] =  H[(r - num_RX * Nconf) * num_TX + (c - num_TX)].x;   
           
            }
		}

		//for (size_t r = 0; r < 2 * num_RX * Nconf; r++) {
		//	for (size_t c = 0; c < 2 * num_TX; c++) {
		//		std::cout << host_matrix[c * (2 * num_RX * Nconf) + r] << " ";  
		//	}
		//	std::cout << std::endl;
		//}

		txs.clear();
		rxs.clear();
    }                  
    
	normalizeVector(host_matrix, num_TX, num_RX);

	/*******************/
	/* SVD CALCULATION */
	/*******************/
    if (use_device) {
		device_matrix = host_matrix;
        deviceSideSVD(device_matrix, singular_values_d, plan, 2 * num_RX, 2 * num_TX, Npop * Nconf);
		computeCapacityDevice(singular_values_d, C_d, SNR_linear, num_TX);
        findMaxChannelCapacityPerGroupDevice(C_d, Cg_d, Nconf);
        Cg_h = Cg_d;
    } else {
        hostSideSVD(host_matrix, singular_values_h, 2 * num_RX, 2 * num_TX, Npop * Nconf);
        computeCapacityHost(singular_values_h, C_h, SNR_linear, num_TX);
        findMaxChannelCapacityPerGroupHost(C_h, Cg_h, Nconf);
    }   

    // --- Initialize the best fitnesses of the parent population with the just computed channel capacities
	for(uint g = 0; g < parent_pop.size(); g++) parent_pop[g].best_fitness = Cg_h[g];    
    
    // --- Initialize the child population
    init_child(child_pop, num_TX, NTXCoeff, num_RX, NRXCoeff, Nconf, rx.radius, TXline, RXline, azr_tx, azr_rx, pattern_tx, pattern_rx, step_tx, step_rx,
               xsi_tx, xsi_rx, LegendreCoeffTX, LegendreCoeffRX);    

    /*********************/
	/* OPTIMIZATION LOOP */
    /*********************/
    size_t freeMemory, totalMemory;

	TimingGPU timerGPU;
	timerGPU.StartCounter();
	// --- Loop over the generations
	for (uint count = 0; count < gen_max; count++) {

		// --- Loop over the group
		for (uint g = 0; g < parent_pop.size(); g++) {
            
			// --- Generate 3 random numbers determining 3 generic groups from which the children are generated
			uint ag, bg, cg;
      		do ag = dist_pop(rng_main); while(ag == g);
    		do bg = dist_pop(rng_main); while(bg == g || bg == ag);
    		do cg = dist_pop(rng_main); while(cg == g || cg == ag || bg == ag);
            
            // --- Generate the new group
            for (uint i = 0; i < parent_pop[g].Nconf; i++) {
                
                // --- Indices of the three parents
                uint ai = dist_group(rng_main);
        		uint bi = dist_group(rng_main);
        		uint ci = dist_group(rng_main);
                    
                // --- Current RX configurations
                float *RX_g_i   = parent_pop[g].get_RXconfiguration(i); 
                float *RX_ag_ai = parent_pop[ag].get_RXconfiguration(ai);                
                float *RX_bg_bi = parent_pop[bg].get_RXconfiguration(bi);                
                float *RX_cg_ci = parent_pop[cg].get_RXconfiguration(ci);                 
                
                float *RX_trial_i = child_pop[g].get_RXconfiguration(i);
                
                // --- Mutation and crossover
                for (int j = 0; j < child_pop[g].NRXCoeff; j++) {
                    if (randb(rng_main) <= CR) RX_trial_i[j] = RX_ag_ai[j] + F * (RX_bg_bi[j] - RX_cg_ci[j]);
                    else RX_trial_i[j] = RX_g_i[j];
                }
            }
            
            // --- Current TX configurations
            float *TX_g  = parent_pop[g].get_TXconfiguration(); 
            float *TX_ag = parent_pop[ag].get_TXconfiguration();                
            float *TX_bg = parent_pop[bg].get_TXconfiguration();                
            float *TX_cg = parent_pop[cg].get_TXconfiguration();                                 
            
			float *TX_trial = child_pop[g].get_TXconfiguration();
            
            // --- Mutation and crossover
            for (int j = 0; j < child_pop[g].NTXCoeff; j++) {
                if (randb(rng_main) <= CR) TX_trial[j] = TX_ag[j]+F*(TX_bg[j]-TX_cg[j]);
                else TX_trial[j] = TX_g[j];
            }
                
        }
       
        //build_positions(child_pop, pos_tx, pos_rx, LegendreCoeffTX, LegendreCoeffRX);
        build_positions_with_constraints(child_pop, pos_tx, pos_rx, xsi_tx, xsi_rx, lambda, step_tx, step_rx, LegendreCoeffTX, LegendreCoeffRX); 
        
		/*********************************/
		/* SCATTERING MATRIX CALCULATION */
		/*********************************/
		
		txs.clear();
		rxs.clear();
		for (uint i = 0; i < Npop ; i++) {

			// --- Transmitting antennas
			for (uint j = 0; j < num_TX; j++) { 
				tx.pos.x		= pos_tx[j + i * num_TX].x;	
				tx.pos.y		= pos_tx[j + i * num_TX].y;	
				tx.pos.z		= pos_tx[j + i * num_TX].z;	
				tx.azimuth		= deg2rad(0.f);
				tx.zenith		= deg2rad(0.f);
				tx.roll			= deg2rad(0.f);
				tx.update_unit_vectors();

				txs.push_back(tx); 
			}
		
			// --- Receiving antennas
			for (uint k = 0; k < Nconf; k++) {
	    
				for(uint j = 0; j < num_RX; j++) {
					rx.pos.x		= pos_rx[j + k * num_RX + i * Nconf * num_RX].x;	
					rx.pos.y		= pos_rx[j + k * num_RX + i * Nconf * num_RX].y;	
					rx.pos.z		= pos_rx[j + k * num_RX + i * Nconf * num_RX].z;	
					rx.azimuth		= deg2rad(0.f);
					rx.zenith 		= deg2rad(0.f);
					rx.roll			= deg2rad(0.f);
					rx.update_unit_vectors();
					rxs.push_back(rx);
					//printf("%f %f %f %f\n", rx.pos.x, rx.pos.y, rx.pos.z, rx.radius);
				}        	    
			}	    

			// --- H is a num_RX * Nconf x num_TX matrix - row-major - it has num_RX * Nconf rows and num_TX columns
			computeScatteringMatrix(argc, argv, numCPU, numGPU, max_cnt, pathfinder_list, mesh, edge_list, global_path_list, num_TX, num_RX * Nconf, 
									txs, rxs, lambda, H, final_iter);

			uint dim = i * (2 * num_TX) * (2 * num_RX * Nconf);
			for (uint r = 0; r < 2 * num_RX * Nconf; r++) {
				for (uint c = 0; c < 2 * num_TX; ++c) {       
      
					// --- Upper-left quadrant
					if(c < num_TX && r < num_RX * Nconf)   host_matrix[dim + c * (2 * num_RX * Nconf) + r] =  H[r                 * num_TX + c           ].x;     
                 
					// --- Upper-right quadrant
					if(c >= num_TX && r < num_RX * Nconf)  host_matrix[dim + c * (2 * num_RX * Nconf) + r] = -H[r                 * num_TX + (c - num_TX)].y;    
                    
					// --- Lower-left quadrant
					if(c < num_TX && r >= num_RX * Nconf)  host_matrix[dim + c * (2 * num_RX * Nconf) + r] =  H[(r - num_RX * Nconf) * num_TX + c].y;    
                    
					// --- Lower-right quadrant
					if(c >= num_TX && r >= num_RX * Nconf) host_matrix[dim + c * (2 * num_RX * Nconf) + r] =  H[(r - num_RX * Nconf) * num_TX + (c - num_TX)].x;   
           
				}
			}

			txs.clear();
			rxs.clear();
		}                  
		
		normalizeVector(host_matrix, num_TX, num_RX);

		/*******************/
		/* SVD CALCULATION */
		/*******************/
		if (use_device) {
			device_matrix = host_matrix;
			deviceSideSVD(device_matrix, singular_values_d, plan, 2 * num_RX, 2 * num_TX, Npop * Nconf);
			computeCapacityDevice(singular_values_d, C_d, SNR_linear, num_TX);
			findMaxChannelCapacityPerGroupDevice(C_d, Cg_d, Nconf);
			Cg_h = Cg_d;
		} else {
			hostSideSVD(host_matrix, singular_values_h, 2 * num_RX, 2 * num_TX, Npop * Nconf);
			computeCapacityHost(singular_values_h, C_h, SNR_linear, num_TX);
			findMaxChannelCapacityPerGroupHost(C_h, Cg_h, Nconf);
		}   
        
        // --- Set the best fitness for each group
        for (uint g = 0; g < child_pop.size(); g++) child_pop[g].best_fitness = Cg_h[g];
        
        // --- Swap the best solutions of parent and child populations
        for (uint g = 0; g < parent_pop.size(); g++) if (child_pop[g].best_fitness > parent_pop[g].best_fitness ) std::swap(child_pop[g], parent_pop[g]);
         
        double maximum;
        // --- Find the best configuration among all the groups for the current generation
		ind_max_group = find_best_among_all_groups(parent_pop,maximum);   

        for (uint group_index = 0; group_index < parent_pop.size(); group_index++) {
            
			// --- Find the index of the best configuration of the group nr. group_index
            if (use_device) ind_max_element = find_best_configuration_in_the_group_d(C_d.begin() + group_index * Nconf, C_d.begin() + group_index * Nconf + Nconf);
            else ind_max_element = find_best_configuration_in_the_group_h(C_h.begin() + group_index*Nconf,C_h.begin() + group_index*Nconf + Nconf);

		}
                 
		// --- Find the index of the best, absolute configuration within the group that has the best element
		if (use_device) ind_max_element = find_best_configuration_in_the_group_d(C_d.begin() + ind_max_group * Nconf, C_d.begin() + ind_max_group * Nconf + Nconf);
		else { 
			printf("Here\n");  
			ind_max_element = find_best_configuration_in_the_group_h(C_h.begin() + ind_max_group * Nconf, C_h.begin() + ind_max_group * Nconf + Nconf); }

		std::cerr<< std::setprecision(8) << "Best Capacity among all groups at generation "<< count << " at index " << ind_max_group << " = " << maximum << std::endl;

		// --- Build the best positions for the current generation  
		build_best_positions_with_constraints(parent_pop[ind_max_group], LegendreCoeffTX, LegendreCoeffRX,
												  best_pos_tx, best_pos_rx, best_h_tx, best_h_rx, xsi_tx,
                                                  xsi_rx, lambda, step_tx, step_rx, ind_max_element);                                 
		std::cerr << "After build best pos for the current generation" << std::endl;
        
    } // --- End generations

	std:: cout << "Timing = " << timerGPU.GetCounter() << "\n";

	/***************************************/
	/* FINAL SCATTERING MATRIX CALCULATION */
	/***************************************/
		
	final_iter = true;
	txs.clear();
	rxs.clear();
	//for (uint i = 0; i < Npop ; i++) {

		// --- Transmitting antennas
		for (uint j = 0; j < num_TX; j++) { 
			tx.pos.x		= best_pos_tx[j].x;	
			tx.pos.y		= best_pos_tx[j].y;	
			tx.pos.z		= best_pos_tx[j].z;	
			printf("Tx nr. %i; x = %f; y = %f; z = %f\n", j, tx.pos.x, tx.pos.y, tx.pos.z);
			tx.azimuth		= deg2rad(0.f);
			tx.zenith		= deg2rad(0.f);
			tx.roll			= deg2rad(0.f);
			tx.update_unit_vectors();

			txs.push_back(tx); 
		}
		
		// --- Receiving antennas
		//for (uint k = 0; k < Nconf; k++) {
	    
			for(uint j = 0; j < num_RX; j++) {
				rx.pos.x		= best_pos_rx[j].x;	
				rx.pos.y		= best_pos_rx[j].y;	
				rx.pos.z		= best_pos_rx[j].z;	
				printf("Rx nr. %i; x = %f; y = %f; z = %f\n", j, rx.pos.x, rx.pos.y, rx.pos.z);
				rx.azimuth		= deg2rad(0.f);
				rx.zenith 		= deg2rad(0.f);
				rx.roll			= deg2rad(0.f);
				rx.update_unit_vectors();
				rxs.push_back(rx);
				//printf("%f %f %f %f\n", rx.pos.x, rx.pos.y, rx.pos.z, rx.radius);
			}        	    
		//}	    

		// --- H is a num_RX * Nconf x num_TX matrix - row-major - it has num_RX * Nconf rows and num_TX columns
		computeScatteringMatrix(argc, argv, numCPU, numGPU, max_cnt, pathfinder_list, mesh, edge_list, global_path_list, num_TX, num_RX * Nconf, 
								txs, rxs, lambda, H, final_iter);

		txs.clear();
		rxs.clear();
	//}                  

	for (size_t i = 0; i < numGPU; i++) device_destroy_path_finder(pathfinder_list[i]);

	pathfinder_list.clear();

	return 0;

}   

