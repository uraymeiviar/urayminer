/**
 * Whirlpool-512 CUDA implementation.
 *
 * ==========================(LICENSE BEGIN)============================
 *
 * Copyright (c) 2014-2016 djm34, tpruvot, SP, Provos Alexis
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 *
 * ===========================(LICENSE END)=============================
 * @author djm34 (initial draft)
 * @author tpruvot (dual old/whirlpool modes, midstate)
 * @author SP ("final" function opt and tuning)
 * @author Provos Alexis (Applied partial shared memory utilization, precomputations, merging & tuning for 970/750ti under CUDA7.5 -> +93% increased throughput of whirlpool)
 */


// Change with caution, used by shared mem fetch
#define TPB80 384
#define TPB64 384

extern "C"
{
#include "sph/sph_whirlpool.h"
#include "miner.h"
}

#include "cuda_helper_alexis.h"
#include "cuda_vectors_alexis2.h"
#include "cuda_whirlpool_tables.cuh"

__device__ static uint64_t b0[256];
__device__ static uint64_t b7[256];

__constant__ static uint2 precomputed_round_key_64[72];
__constant__ static uint2 precomputed_round_key_80[80];

__device__ static uint2 c_PaddedMessage80[16];


/**
 * Round constants.
 */
__device__ uint2 InitVector_RC[10];

//--------START OF WHIRLPOOL DEVICE MACROS---------------------------------------------------------------------------
__device__ __forceinline__
void static TRANSFER(uint2 *const __restrict__ dst,const uint2 *const __restrict__ src){
	dst[0] = src[ 0];
	dst[1] = src[ 1];
	dst[2] = src[ 2];
	dst[3] = src[ 3];
	dst[4] = src[ 4];
	dst[5] = src[ 5];
	dst[6] = src[ 6];
	dst[7] = src[ 7];
}

__device__ __forceinline__
static uint2 d_ROUND_ELT_LDG(const uint2 sharedMemory[7][256],const uint2 *const __restrict__ in,const int i0, const int i1, const int i2, const int i3, const int i4, const int i5, const int i6, const int i7){
	uint2 ret = __ldg((uint2*)&b0[__byte_perm(in[i0].x, 0, 0x4440)]);
	ret ^= sharedMemory[1][__byte_perm(in[i1].x, 0, 0x4441)];
	ret ^= sharedMemory[2][__byte_perm(in[i2].x, 0, 0x4442)];
	ret ^= sharedMemory[3][__byte_perm(in[i3].x, 0, 0x4443)];
	ret ^= sharedMemory[4][__byte_perm(in[i4].y, 0, 0x4440)];
	ret ^= ROR24(__ldg((uint2*)&b0[__byte_perm(in[i5].y, 0, 0x4441)]));
	ret ^= ROR8(__ldg((uint2*)&b7[__byte_perm(in[i6].y, 0, 0x4442)]));
	ret ^= __ldg((uint2*)&b7[__byte_perm(in[i7].y, 0, 0x4443)]);
	return ret;
}

__device__ __forceinline__
static uint2 d_ROUND_ELT(const uint2 sharedMemory[7][256],const uint2 *const __restrict__ in,const int i0, const int i1, const int i2, const int i3, const int i4, const int i5, const int i6, const int i7){

	uint2 ret = __ldg((uint2*)&b0[__byte_perm(in[i0].x, 0, 0x4440)]);
	ret ^= sharedMemory[1][__byte_perm(in[i1].x, 0, 0x4441)];
	ret ^= sharedMemory[2][__byte_perm(in[i2].x, 0, 0x4442)];
	ret ^= sharedMemory[3][__byte_perm(in[i3].x, 0, 0x4443)];
	ret ^= sharedMemory[4][__byte_perm(in[i4].y, 0, 0x4440)];
	ret ^= sharedMemory[5][__byte_perm(in[i5].y, 0, 0x4441)];
	ret ^= ROR8(__ldg((uint2*)&b7[__byte_perm(in[i6].y, 0, 0x4442)]));
	ret ^= __ldg((uint2*)&b7[__byte_perm(in[i7].y, 0, 0x4443)]);
	return ret;
}

__device__ __forceinline__
static uint2 d_ROUND_ELT1_LDG(const uint2 sharedMemory[7][256],const uint2 *const __restrict__ in,const int i0, const int i1, const int i2, const int i3, const int i4, const int i5, const int i6, const int i7, const uint2 c0){

	uint2 ret = __ldg((uint2*)&b0[__byte_perm(in[i0].x, 0, 0x4440)]);
	ret ^= sharedMemory[1][__byte_perm(in[i1].x, 0, 0x4441)];
	ret ^= sharedMemory[2][__byte_perm(in[i2].x, 0, 0x4442)];
	ret ^= sharedMemory[3][__byte_perm(in[i3].x, 0, 0x4443)];
	ret ^= sharedMemory[4][__byte_perm(in[i4].y, 0, 0x4440)];
	ret ^= ROR24(__ldg((uint2*)&b0[__byte_perm(in[i5].y, 0, 0x4441)]));
	ret ^= ROR8(__ldg((uint2*)&b7[__byte_perm(in[i6].y, 0, 0x4442)]));
	ret ^= __ldg((uint2*)&b7[__byte_perm(in[i7].y, 0, 0x4443)]);
	ret ^= c0;
	return ret;
}

__device__ __forceinline__
static uint2 d_ROUND_ELT1(const uint2 sharedMemory[7][256],const uint2 *const __restrict__ in,const int i0, const int i1, const int i2, const int i3, const int i4, const int i5, const int i6, const int i7, const uint2 c0){
	uint2 ret = __ldg((uint2*)&b0[__byte_perm(in[i0].x, 0, 0x4440)]);
	ret ^= sharedMemory[1][__byte_perm(in[i1].x, 0, 0x4441)];
	ret ^= sharedMemory[2][__byte_perm(in[i2].x, 0, 0x4442)];
	ret ^= sharedMemory[3][__byte_perm(in[i3].x, 0, 0x4443)];
	ret ^= sharedMemory[4][__byte_perm(in[i4].y, 0, 0x4440)];
	ret ^= sharedMemory[5][__byte_perm(in[i5].y, 0, 0x4441)];
	ret ^= ROR8(__ldg((uint2*)&b7[__byte_perm(in[i6].y, 0, 0x4442)]));//sharedMemory[6][__byte_perm(in[i6].y, 0, 0x4442)]
	ret ^= __ldg((uint2*)&b7[__byte_perm(in[i7].y, 0, 0x4443)]);//sharedMemory[7][__byte_perm(in[i7].y, 0, 0x4443)]
	ret ^= c0;
	return ret;
}

//--------END OF WHIRLPOOL DEVICE MACROS-----------------------------------------------------------------------------

//--------START OF WHIRLPOOL HOST MACROS-----------------------------------------------------------------------------

#define table_skew(val,num) SPH_ROTL64(val,8*num)
#define BYTE(x, n)     ((unsigned)((x) >> (8 * (n))) & 0xFF)

#define ROUND_ELT(table, in, i0, i1, i2, i3, i4, i5, i6, i7) \
	(table[BYTE(in[i0], 0)] \
	^ table_skew(table[BYTE(in[i1], 1)], 1) \
	^ table_skew(table[BYTE(in[i2], 2)], 2) \
	^ table_skew(table[BYTE(in[i3], 3)], 3) \
	^ table_skew(table[BYTE(in[i4], 4)], 4) \
	^ table_skew(table[BYTE(in[i5], 5)], 5) \
	^ table_skew(table[BYTE(in[i6], 6)], 6) \
	^ table_skew(table[BYTE(in[i7], 7)], 7))

#define ROUND(table, in, out, c0, c1, c2, c3, c4, c5, c6, c7)   do { \
		out[0] = ROUND_ELT(table, in, 0, 7, 6, 5, 4, 3, 2, 1) ^ c0; \
		out[1] = ROUND_ELT(table, in, 1, 0, 7, 6, 5, 4, 3, 2) ^ c1; \
		out[2] = ROUND_ELT(table, in, 2, 1, 0, 7, 6, 5, 4, 3) ^ c2; \
		out[3] = ROUND_ELT(table, in, 3, 2, 1, 0, 7, 6, 5, 4) ^ c3; \
		out[4] = ROUND_ELT(table, in, 4, 3, 2, 1, 0, 7, 6, 5) ^ c4; \
		out[5] = ROUND_ELT(table, in, 5, 4, 3, 2, 1, 0, 7, 6) ^ c5; \
		out[6] = ROUND_ELT(table, in, 6, 5, 4, 3, 2, 1, 0, 7) ^ c6; \
		out[7] = ROUND_ELT(table, in, 7, 6, 5, 4, 3, 2, 1, 0) ^ c7; \
	} while (0)

__host__
static void ROUND_KSCHED(const uint64_t *in,uint64_t *out,const uint64_t c){
	const uint64_t *a = in;
	uint64_t *b = out;
	ROUND(old1_T0, a, b, c, 0, 0, 0, 0, 0, 0, 0);
}


//--------END OF WHIRLPOOL HOST MACROS-------------------------------------------------------------------------------

__host__
extern void x15_whirlpool_cpu_init(int thr_id, uint32_t threads, int mode){

	uint64_t* table0 = NULL;

	switch (mode) {
	case 0: /* x15 with rotated T1-T7 (based on T0) */
		table0 = (uint64_t*)plain_T0;
		cudaMemcpyToSymbol(InitVector_RC, plain_RC, 10*sizeof(uint64_t),0, cudaMemcpyHostToDevice);
		cudaMemcpyToSymbol(precomputed_round_key_64, plain_precomputed_round_key_64, 72*sizeof(uint64_t),0, cudaMemcpyHostToDevice);
		break;
	case 1: /* old whirlpool */
		table0 = (uint64_t*)old1_T0;
		cudaMemcpyToSymbol(InitVector_RC, old1_RC, 10*sizeof(uint64_t),0,cudaMemcpyHostToDevice);
		cudaMemcpyToSymbol(precomputed_round_key_64, old1_precomputed_round_key_64, 72*sizeof(uint64_t),0, cudaMemcpyHostToDevice);
		break;
	default:
		applog(LOG_ERR,"Bad whirlpool mode");
		exit(0);
	}
	cudaMemcpyToSymbol(b0, table0, 256*sizeof(uint64_t),0, cudaMemcpyHostToDevice);
	uint64_t table7[256];
	for(int i=0;i<256;i++){
		table7[i] = ROTR64(table0[i],8);
	}
	cudaMemcpyToSymbol(b7, table7, 256*sizeof(uint64_t),0, cudaMemcpyHostToDevice);
}

static void whirl_midstate(void *state, const void *input)
{
	sph_whirlpool_context ctx;

	sph_whirlpool1_init(&ctx);
	sph_whirlpool1(&ctx, input, 64);

	memcpy(state, ctx.state, 64);
}

__host__
void whirlpool512_setBlock_80(void *pdata, const void *ptarget)
{
	uint64_t PaddedMessage[16];

	memcpy(PaddedMessage, pdata, 80);
	memset(((uint8_t*)&PaddedMessage)+80, 0, 48);
	((uint8_t*)&PaddedMessage)[80] = 0x80; /* ending */

	// compute constant first block
	uint64_t midstate[16] = { 0 };
	whirl_midstate(midstate, pdata);
	memcpy(PaddedMessage, midstate, 64);

	uint64_t round_constants[80];
	uint64_t n[8];
	
	n[0] = PaddedMessage[0] ^ PaddedMessage[8];    //read data
	n[1] = PaddedMessage[1] ^ PaddedMessage[9];
	n[2] = PaddedMessage[2] ^ 0x0000000000000080; //whirlpool
	n[3] = PaddedMessage[3];
	n[4] = PaddedMessage[4];
	n[5] = PaddedMessage[5];
	n[6] = PaddedMessage[6];
	n[7] = PaddedMessage[7] ^ 0x8002000000000000;
	
	ROUND_KSCHED(PaddedMessage,round_constants,old1_RC[0]);
	
	for(int i=1;i<10;i++){
		ROUND_KSCHED(&round_constants[8*(i-1)],&round_constants[8*i],old1_RC[i]);	
	}

	//USE the same memory place to store keys and state
	round_constants[ 0]^= old1_T0[BYTE(n[0], 0)]
			   ^  table_skew(old1_T0[BYTE(n[7], 1)], 1) ^ table_skew(old1_T0[BYTE(n[6], 2)], 2) ^ table_skew(old1_T0[BYTE(n[5], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[4], 4)], 4) ^ table_skew(old1_T0[BYTE(n[3], 5)], 5) ^ table_skew(old1_T0[BYTE(n[2], 6)], 6);

	round_constants[ 1]^= old1_T0[BYTE(n[1], 0)]
			   ^  table_skew(old1_T0[BYTE(n[0], 1)], 1) ^ table_skew(old1_T0[BYTE(n[7], 2)], 2) ^ table_skew(old1_T0[BYTE(n[6], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[5], 4)], 4) ^ table_skew(old1_T0[BYTE(n[4], 5)], 5) ^ table_skew(old1_T0[BYTE(n[3], 6)], 6)
			   ^  table_skew(old1_T0[BYTE(n[2], 7)], 7);

	round_constants[ 2]^= old1_T0[BYTE(n[2], 0)]
			   ^  table_skew(old1_T0[BYTE(n[1], 1)], 1) ^ table_skew(old1_T0[BYTE(n[0], 2)], 2) ^ table_skew(old1_T0[BYTE(n[7], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[6], 4)], 4) ^ table_skew(old1_T0[BYTE(n[5], 5)], 5) ^ table_skew(old1_T0[BYTE(n[4], 6)], 6)
			   ^  table_skew(old1_T0[BYTE(n[3], 7)], 7);

	round_constants[ 3]^= old1_T0[BYTE(n[3], 0)]
			   ^  table_skew(old1_T0[BYTE(n[2], 1)], 1) ^ table_skew(old1_T0[BYTE(n[1], 2)], 2) ^ table_skew(old1_T0[BYTE(n[0], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[7], 4)], 4) ^ table_skew(old1_T0[BYTE(n[6], 5)], 5) ^ table_skew(old1_T0[BYTE(n[5], 6)], 6)
			   ^  table_skew(old1_T0[BYTE(n[4], 7)], 7);

	round_constants[ 4]^= old1_T0[BYTE(n[4], 0)]
			   ^  table_skew(old1_T0[BYTE(n[3], 1)], 1) ^ table_skew(old1_T0[BYTE(n[2], 2)], 2) ^ table_skew(old1_T0[BYTE(n[1], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[0], 4)], 4) ^ table_skew(old1_T0[BYTE(n[7], 5)], 5) ^ table_skew(old1_T0[BYTE(n[6], 6)], 6)
			   ^  table_skew(old1_T0[BYTE(n[5], 7)], 7);

	round_constants[ 5]^= old1_T0[BYTE(n[5], 0)]
			   ^  table_skew(old1_T0[BYTE(n[4], 1)], 1) ^ table_skew(old1_T0[BYTE(n[3], 2)], 2) ^ table_skew(old1_T0[BYTE(n[2], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[0], 5)], 5) ^ table_skew(old1_T0[BYTE(n[7], 6)], 6) ^ table_skew(old1_T0[BYTE(n[6], 7)], 7);

	round_constants[ 6]^= old1_T0[BYTE(n[6], 0)]
			   ^  table_skew(old1_T0[BYTE(n[5], 1)], 1) ^ table_skew(old1_T0[BYTE(n[4], 2)], 2) ^ table_skew(old1_T0[BYTE(n[3], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[2], 4)], 4) ^ table_skew(old1_T0[BYTE(n[0], 6)], 6) ^  table_skew(old1_T0[BYTE(n[7], 7)], 7);

	round_constants[ 7]^= old1_T0[BYTE(n[7], 0)]
			   ^  table_skew(old1_T0[BYTE(n[6], 1)], 1) ^ table_skew(old1_T0[BYTE(n[5], 2)], 2) ^ table_skew(old1_T0[BYTE(n[4], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[3], 4)], 4) ^ table_skew(old1_T0[BYTE(n[2], 5)], 5) ^ table_skew(old1_T0[BYTE(n[0], 7)], 7);

	for(int i=1;i<5;i++)
		n[i] = round_constants[i];

	round_constants[ 8]^= table_skew(old1_T0[BYTE(n[4], 4)], 4) ^ table_skew(old1_T0[BYTE(n[3], 5)], 5) ^ table_skew(old1_T0[BYTE(n[2], 6)], 6)
			   ^  table_skew(old1_T0[BYTE(n[1], 7)], 7);

	round_constants[ 9]^= old1_T0[BYTE(n[1], 0)]
			   ^ table_skew(old1_T0[BYTE(n[4], 5)], 5) ^ table_skew(old1_T0[BYTE(n[3], 6)], 6) ^  table_skew(old1_T0[BYTE(n[2], 7)], 7);

	round_constants[10]^= old1_T0[BYTE(n[2], 0)]
			   ^  table_skew(old1_T0[BYTE(n[1], 1)], 1) ^ table_skew(old1_T0[BYTE(n[4], 6)], 6) ^ table_skew(old1_T0[BYTE(n[3], 7)], 7);

	round_constants[11]^= old1_T0[BYTE(n[3], 0)]
			   ^  table_skew(old1_T0[BYTE(n[2], 1)], 1) ^ table_skew(old1_T0[BYTE(n[1], 2)], 2) ^  table_skew(old1_T0[BYTE(n[4], 7)], 7);

	round_constants[12]^= old1_T0[BYTE(n[4], 0)]
			   ^  table_skew(old1_T0[BYTE(n[3], 1)], 1) ^ table_skew(old1_T0[BYTE(n[2], 2)], 2) ^ table_skew(old1_T0[BYTE(n[1], 3)], 3);

	round_constants[13]^= table_skew(old1_T0[BYTE(n[4], 1)], 1) ^ table_skew(old1_T0[BYTE(n[3], 2)], 2) ^ table_skew(old1_T0[BYTE(n[2], 3)], 3)
			   ^  table_skew(old1_T0[BYTE(n[1], 4)], 4);

	round_constants[14]^= table_skew(old1_T0[BYTE(n[4], 2)], 2) ^ table_skew(old1_T0[BYTE(n[3], 3)], 3) ^ table_skew(old1_T0[BYTE(n[2], 4)], 4)
			   ^  table_skew(old1_T0[BYTE(n[1], 5)], 5);

	round_constants[15]^= table_skew(old1_T0[BYTE(n[4], 3)], 3) ^  table_skew(old1_T0[BYTE(n[3], 4)], 4) ^ table_skew(old1_T0[BYTE(n[2], 5)], 5)
			   ^ table_skew(old1_T0[BYTE(n[1], 6)], 6);

	PaddedMessage[0] ^= PaddedMessage[8];
	
	cudaMemcpyToSymbol(c_PaddedMessage80, PaddedMessage, 128, 0, cudaMemcpyHostToDevice);

	cudaMemcpyToSymbol(precomputed_round_key_80, round_constants, 80*sizeof(uint64_t), 0, cudaMemcpyHostToDevice);
}

__host__
extern void x15_whirlpool_cpu_free(int thr_id){
	cudaFree(InitVector_RC);
	cudaFree(b0);
	cudaFree(b7);
}

__global__ __launch_bounds__(TPB80,2)
void oldwhirlpool_gpu_hash_80(uint32_t threads, uint32_t startNounce, uint32_t* resNonce, const uint64_t target){

	__shared__ uint2 sharedMemory[7][256];

	if (threadIdx.x < 256) {
		const uint2 tmp = __ldg((uint2*)&b0[threadIdx.x]);
		sharedMemory[0][threadIdx.x] = tmp;
		sharedMemory[1][threadIdx.x] = ROL8(tmp);
		sharedMemory[2][threadIdx.x] = ROL16(tmp);
		sharedMemory[3][threadIdx.x] = ROL24(tmp);
		sharedMemory[4][threadIdx.x] = SWAPUINT2(tmp);
		sharedMemory[5][threadIdx.x] = ROR24(tmp);
		sharedMemory[6][threadIdx.x] = ROR16(tmp);
	}

	__syncthreads();

	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	
	if (thread < threads){

		uint2 hash[8], state[8],n[8], tmp[8];
		uint32_t nonce = cuda_swab32(startNounce + thread);
		uint2 temp = c_PaddedMessage80[9];
		temp.y = nonce;

		/// round 2 ///////
		//////////////////////////////////
		temp = temp ^ c_PaddedMessage80[1];

		*(uint2x4*)&n[ 0]   = *(uint2x4*)&precomputed_round_key_80[ 0];
		*(uint2x4*)&n[ 4]   = *(uint2x4*)&precomputed_round_key_80[ 4];
		*(uint2x4*)&tmp[ 0] = *(uint2x4*)&precomputed_round_key_80[ 8];
		*(uint2x4*)&tmp[ 4] = *(uint2x4*)&precomputed_round_key_80[12];
		
		n[ 0]^= __ldg((uint2*)&b7[__byte_perm(temp.y, 0, 0x4443)]);
		n[ 5]^= sharedMemory[4][__byte_perm(temp.y, 0, 0x4440)];
		n[ 6]^= sharedMemory[5][__byte_perm(temp.y, 0, 0x4441)];
		n[ 7]^= sharedMemory[6][__byte_perm(temp.y, 0, 0x4442)];
		
		tmp[ 0]^= __ldg((uint2*)&b0[__byte_perm(n[0].x, 0, 0x4440)]);
		tmp[ 0]^= sharedMemory[1][__byte_perm(n[7].x, 0, 0x4441)];
		tmp[ 0]^= sharedMemory[2][__byte_perm(n[6].x, 0, 0x4442)];
		tmp[ 0]^= sharedMemory[3][__byte_perm(n[5].x, 0, 0x4443)];

		tmp[ 1]^= sharedMemory[1][__byte_perm(n[0].x, 0, 0x4441)];
		tmp[ 1]^= sharedMemory[2][__byte_perm(n[7].x, 0, 0x4442)];
		tmp[ 1]^= sharedMemory[3][__byte_perm(n[6].x, 0, 0x4443)];
		tmp[ 1]^= sharedMemory[4][__byte_perm(n[5].y, 0, 0x4440)];
		
		tmp[ 2]^= sharedMemory[2][__byte_perm(n[0].x, 0, 0x4442)];
		tmp[ 2]^= sharedMemory[3][__byte_perm(n[7].x, 0, 0x4443)];
		tmp[ 2]^= sharedMemory[4][__byte_perm(n[6].y, 0, 0x4440)];
		tmp[ 2]^= sharedMemory[5][__byte_perm(n[5].y, 0, 0x4441)];

		tmp[ 3]^= sharedMemory[3][__byte_perm(n[0].x, 0, 0x4443)];
		tmp[ 3]^= sharedMemory[4][__byte_perm(n[7].y, 0, 0x4440)];
		tmp[ 3]^= ROR24(__ldg((uint2*)&b0[__byte_perm(n[6].y, 0, 0x4441)]));
		tmp[ 3]^= ROR8(__ldg((uint2*)&b7[__byte_perm(n[5].y, 0, 0x4442)]));

		tmp[ 4]^= sharedMemory[4][__byte_perm(n[0].y, 0, 0x4440)];
		tmp[ 4]^= sharedMemory[5][__byte_perm(n[7].y, 0, 0x4441)];
		tmp[ 4]^= ROR8(__ldg((uint2*)&b7[__byte_perm(n[6].y, 0, 0x4442)]));
		tmp[ 4]^= __ldg((uint2*)&b7[__byte_perm(n[5].y, 0, 0x4443)]);
	
		tmp[ 5]^= __ldg((uint2*)&b0[__byte_perm(n[5].x, 0, 0x4440)]);
		tmp[ 5]^= sharedMemory[5][__byte_perm(n[0].y, 0, 0x4441)];
		tmp[ 5]^= sharedMemory[6][__byte_perm(n[7].y, 0, 0x4442)];
		tmp[ 5]^= __ldg((uint2*)&b7[__byte_perm(n[6].y, 0, 0x4443)]);

		tmp[ 6]^= __ldg((uint2*)&b0[__byte_perm(n[6].x, 0, 0x4440)]);
		tmp[ 6]^= sharedMemory[1][__byte_perm(n[5].x, 0, 0x4441)];
		tmp[ 6]^= sharedMemory[6][__byte_perm(n[0].y, 0, 0x4442)];
		tmp[ 6]^= __ldg((uint2*)&b7[__byte_perm(n[7].y, 0, 0x4443)]);

		tmp[ 7]^= __ldg((uint2*)&b0[__byte_perm(n[7].x, 0, 0x4440)]);
		tmp[ 7]^= sharedMemory[1][__byte_perm(n[6].x, 0, 0x4441)];
		tmp[ 7]^= sharedMemory[2][__byte_perm(n[5].x, 0, 0x4442)];
		tmp[ 7]^= __ldg((uint2*)&b7[__byte_perm(n[0].y, 0, 0x4443)]);
		
		TRANSFER(n, tmp);

		for (int i=2; i<10; i++) {
			tmp[ 0] = d_ROUND_ELT1_LDG(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, precomputed_round_key_80[i*8+0]);
			tmp[ 1] = d_ROUND_ELT1(    sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, precomputed_round_key_80[i*8+1]);
			tmp[ 2] = d_ROUND_ELT1(    sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, precomputed_round_key_80[i*8+2]);
			tmp[ 3] = d_ROUND_ELT1_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, precomputed_round_key_80[i*8+3]);
			tmp[ 4] = d_ROUND_ELT1_LDG(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, precomputed_round_key_80[i*8+4]);
			tmp[ 5] = d_ROUND_ELT1(    sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, precomputed_round_key_80[i*8+5]);
			tmp[ 6] = d_ROUND_ELT1(    sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, precomputed_round_key_80[i*8+6]);
			tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, precomputed_round_key_80[i*8+7]);
			TRANSFER(n, tmp);
		}

		state[0] = c_PaddedMessage80[0] ^ n[0];
		state[1] = c_PaddedMessage80[1] ^ n[1] ^ vectorize(REPLACE_HIDWORD(devectorize(c_PaddedMessage80[9]),nonce));
		state[2] = c_PaddedMessage80[2] ^ n[2] ^ vectorize(0x0000000000000080);
		state[3] = c_PaddedMessage80[3] ^ n[3];
		state[4] = c_PaddedMessage80[4] ^ n[4];
		state[5] = c_PaddedMessage80[5] ^ n[5];
		state[6] = c_PaddedMessage80[6] ^ n[6];
		state[7] = c_PaddedMessage80[7] ^ n[7] ^ vectorize(0x8002000000000000);

		#pragma unroll 2
		for(int r=0;r<2;r++){
			#pragma unroll 8
			for(int i=0;i<8;i++)
				hash[ i] = n[ i] = state[ i];

			uint2 h[8] = {
				{0xC0EE0B30,0x672990AF},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},
				{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828}
			};

			tmp[ 0] = d_ROUND_ELT1_LDG(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, h[0]);
			tmp[ 1] = d_ROUND_ELT1(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, h[1]);
			tmp[ 2] = d_ROUND_ELT1(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, h[2]);
			tmp[ 3] = d_ROUND_ELT1_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, h[3]);
			tmp[ 4] = d_ROUND_ELT1(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, h[4]);
			tmp[ 5] = d_ROUND_ELT1_LDG(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, h[5]);
			tmp[ 6] = d_ROUND_ELT1(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, h[6]);
			tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, h[7]);
			TRANSFER(n, tmp);
	//		#pragma unroll 10
			for (int i=1; i <10; i++){
				tmp[ 0] = d_ROUND_ELT1_LDG(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, precomputed_round_key_64[(i-1)*8+0]);
				tmp[ 1] = d_ROUND_ELT1(    sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, precomputed_round_key_64[(i-1)*8+1]);
				tmp[ 2] = d_ROUND_ELT1(    sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, precomputed_round_key_64[(i-1)*8+2]);
				tmp[ 3] = d_ROUND_ELT1_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, precomputed_round_key_64[(i-1)*8+3]);
				tmp[ 4] = d_ROUND_ELT1(    sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, precomputed_round_key_64[(i-1)*8+4]);
				tmp[ 5] = d_ROUND_ELT1(    sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, precomputed_round_key_64[(i-1)*8+5]);
				tmp[ 6] = d_ROUND_ELT1(    sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, precomputed_round_key_64[(i-1)*8+6]);
				tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, precomputed_round_key_64[(i-1)*8+7]);
				TRANSFER(n, tmp);
			}
			#pragma unroll 8
			for (int i=0; i<8; i++)
				state[i] = n[i] ^ hash[i];

			#pragma unroll 6
			for (int i=1; i<7; i++)
				n[i]=vectorize(0);

			n[0] = vectorize(0x80);
			n[7] = vectorize(0x2000000000000);

			#pragma unroll 8
			for (int i=0; i < 8; i++) {
				h[i] = state[i];
				n[i] = n[i] ^ h[i];
			}

	//		#pragma unroll 10
			for (int i=0; i < 10; i++) {
				tmp[ 0] = d_ROUND_ELT1(sharedMemory, h, 0, 7, 6, 5, 4, 3, 2, 1, InitVector_RC[i]);
				tmp[ 1] = d_ROUND_ELT(sharedMemory, h, 1, 0, 7, 6, 5, 4, 3, 2);
				tmp[ 2] = d_ROUND_ELT_LDG(sharedMemory, h, 2, 1, 0, 7, 6, 5, 4, 3);
				tmp[ 3] = d_ROUND_ELT(sharedMemory, h, 3, 2, 1, 0, 7, 6, 5, 4);
				tmp[ 4] = d_ROUND_ELT_LDG(sharedMemory, h, 4, 3, 2, 1, 0, 7, 6, 5);
				tmp[ 5] = d_ROUND_ELT(sharedMemory, h, 5, 4, 3, 2, 1, 0, 7, 6);
				tmp[ 6] = d_ROUND_ELT_LDG(sharedMemory, h, 6, 5, 4, 3, 2, 1, 0, 7);
				tmp[ 7] = d_ROUND_ELT(sharedMemory, h, 7, 6, 5, 4, 3, 2, 1, 0);
				TRANSFER(h, tmp);
				tmp[ 0] = d_ROUND_ELT1(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, tmp[0]);
				tmp[ 1] = d_ROUND_ELT1(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, tmp[1]);
				tmp[ 2] = d_ROUND_ELT1_LDG(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, tmp[2]);
				tmp[ 3] = d_ROUND_ELT1(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, tmp[3]);
				tmp[ 4] = d_ROUND_ELT1(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, tmp[4]);
				tmp[ 5] = d_ROUND_ELT1(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, tmp[5]);
				tmp[ 6] = d_ROUND_ELT1(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, tmp[6]);
				tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, tmp[7]);
				TRANSFER(n, tmp);
			}

			state[0] = xor3x(state[0], n[0], vectorize(0x80));
			state[1] = state[1]^ n[1];
			state[2] = state[2]^ n[2];
			state[3] = state[3]^ n[3];
			state[4] = state[4]^ n[4];
			state[5] = state[5]^ n[5];
			state[6] = state[6]^ n[6];
			state[7] = xor3x(state[7], n[7], vectorize(0x2000000000000));
		}

		uint2 h[8] = {
			{0xC0EE0B30,0x672990AF},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},
			{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828}
		};
		
		#pragma unroll 8
		for(int i=0;i<8;i++)
			n[i]=hash[i] = state[ i];

		tmp[ 0] = d_ROUND_ELT1(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, h[0]);
		tmp[ 1] = d_ROUND_ELT1_LDG(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, h[1]);
		tmp[ 2] = d_ROUND_ELT1(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, h[2]);
		tmp[ 3] = d_ROUND_ELT1_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, h[3]);
		tmp[ 4] = d_ROUND_ELT1(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, h[4]);
		tmp[ 5] = d_ROUND_ELT1_LDG(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, h[5]);
		tmp[ 6] = d_ROUND_ELT1(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, h[6]);
		tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, h[7]);
		TRANSFER(n, tmp);
//		#pragma unroll 10
		for (int i=1; i <10; i++){
			tmp[ 0] = d_ROUND_ELT1_LDG(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, precomputed_round_key_64[(i-1)*8+0]);
			tmp[ 1] = d_ROUND_ELT1(    sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, precomputed_round_key_64[(i-1)*8+1]);
			tmp[ 2] = d_ROUND_ELT1(    sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, precomputed_round_key_64[(i-1)*8+2]);
			tmp[ 3] = d_ROUND_ELT1_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, precomputed_round_key_64[(i-1)*8+3]);
			tmp[ 4] = d_ROUND_ELT1(    sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, precomputed_round_key_64[(i-1)*8+4]);
			tmp[ 5] = d_ROUND_ELT1(    sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, precomputed_round_key_64[(i-1)*8+5]);
			tmp[ 6] = d_ROUND_ELT1(    sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, precomputed_round_key_64[(i-1)*8+6]);
			tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, precomputed_round_key_64[(i-1)*8+7]);
			TRANSFER(n, tmp);
		}

		#pragma unroll 8
		for (int i=0; i<8; i++)
			n[ i] = h[i] = n[i] ^ hash[i];

		uint2 backup = h[ 3];
		
		n[0]^= vectorize(0x80);
		n[7]^= vectorize(0x2000000000000);

//		#pragma unroll 8
		for (int i=0; i < 8; i++) {
			tmp[ 0] = d_ROUND_ELT1(sharedMemory, h, 0, 7, 6, 5, 4, 3, 2, 1, InitVector_RC[i]);
			tmp[ 1] = d_ROUND_ELT(sharedMemory, h, 1, 0, 7, 6, 5, 4, 3, 2);
			tmp[ 2] = d_ROUND_ELT_LDG(sharedMemory, h, 2, 1, 0, 7, 6, 5, 4, 3);
			tmp[ 3] = d_ROUND_ELT(sharedMemory, h, 3, 2, 1, 0, 7, 6, 5, 4);
			tmp[ 4] = d_ROUND_ELT_LDG(sharedMemory, h, 4, 3, 2, 1, 0, 7, 6, 5);
			tmp[ 5] = d_ROUND_ELT(sharedMemory, h, 5, 4, 3, 2, 1, 0, 7, 6);
			tmp[ 6] = d_ROUND_ELT_LDG(sharedMemory, h, 6, 5, 4, 3, 2, 1, 0, 7);
			tmp[ 7] = d_ROUND_ELT(sharedMemory, h, 7, 6, 5, 4, 3, 2, 1, 0);
			TRANSFER(h, tmp);
			tmp[ 0] = d_ROUND_ELT1(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, tmp[0]);
			tmp[ 1] = d_ROUND_ELT1(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, tmp[1]);
			tmp[ 2] = d_ROUND_ELT1_LDG(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, tmp[2]);
			tmp[ 3] = d_ROUND_ELT1(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, tmp[3]);
			tmp[ 4] = d_ROUND_ELT1(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, tmp[4]);
			tmp[ 5] = d_ROUND_ELT1(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, tmp[5]);
			tmp[ 6] = d_ROUND_ELT1(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, tmp[6]);
			tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, tmp[7]);
			TRANSFER(n, tmp);
		}
		tmp[ 0] = d_ROUND_ELT1(sharedMemory, h, 0, 7, 6, 5, 4, 3, 2, 1, InitVector_RC[8]);
		tmp[ 1] = d_ROUND_ELT(sharedMemory, h, 1, 0, 7, 6, 5, 4, 3, 2);
		tmp[ 2] = d_ROUND_ELT_LDG(sharedMemory, h, 2, 1, 0, 7, 6, 5, 4, 3);
		tmp[ 3] = d_ROUND_ELT(sharedMemory, h, 3, 2, 1, 0, 7, 6, 5, 4);
		tmp[ 4] = d_ROUND_ELT_LDG(sharedMemory, h, 4, 3, 2, 1, 0, 7, 6, 5);
		tmp[ 5] = d_ROUND_ELT(sharedMemory, h, 5, 4, 3, 2, 1, 0, 7, 6);
		tmp[ 6] = d_ROUND_ELT(sharedMemory, h, 6, 5, 4, 3, 2, 1, 0, 7);
		tmp[ 7] = d_ROUND_ELT(sharedMemory, h, 7, 6, 5, 4, 3, 2, 1, 0);
		TRANSFER(h, tmp);
		tmp[ 0] = d_ROUND_ELT1(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, tmp[0]);
		tmp[ 1] = d_ROUND_ELT1(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, tmp[1]);
		tmp[ 2] = d_ROUND_ELT1(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, tmp[2]);
		tmp[ 3] = d_ROUND_ELT1(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, tmp[3]);
		tmp[ 4] = d_ROUND_ELT1(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, tmp[4]);
		tmp[ 5] = d_ROUND_ELT1(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, tmp[5]);
		tmp[ 6] = d_ROUND_ELT1_LDG(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, tmp[6]);
		tmp[ 7] = d_ROUND_ELT1(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, tmp[7]);
		
		n[ 3] = backup ^ d_ROUND_ELT(sharedMemory,  h, 3, 2, 1, 0, 7, 6, 5, 4) ^ d_ROUND_ELT(sharedMemory,tmp, 3, 2, 1, 0, 7, 6, 5, 4);
		
		if(devectorize(n[3]) <= target){
			uint32_t tmp = atomicExch(&resNonce[0], thread);
			if (tmp != UINT32_MAX)
				resNonce[1] = tmp;		
		}

	} // thread < threads
}

__host__
void whirlpool512_cpu_hash_80(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_resNonce, const uint64_t target)
{
	dim3 grid((threads + TPB80-1) / TPB80);
	dim3 block(TPB80);

	oldwhirlpool_gpu_hash_80<<<grid, block>>>(threads, startNounce,d_resNonce,target);
}

__global__ __launch_bounds__(TPB64,2)
void x15_whirlpool_gpu_hash_64(uint32_t threads, uint64_t *g_hash)
{
	__shared__ uint2 sharedMemory[7][256];

	if (threadIdx.x < 256) {
		const uint2 tmp = __ldg((uint2*)&b0[threadIdx.x]);
		sharedMemory[0][threadIdx.x] = tmp;
		sharedMemory[1][threadIdx.x] = ROL8(tmp);
		sharedMemory[2][threadIdx.x] = ROL16(tmp);
		sharedMemory[3][threadIdx.x] = ROL24(tmp);
		sharedMemory[4][threadIdx.x] = SWAPUINT2(tmp);
		sharedMemory[5][threadIdx.x] = ROR24(tmp);
		sharedMemory[6][threadIdx.x] = ROR16(tmp);
	}

	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	if (thread < threads){

		uint2 hash[8], n[8], h[ 8];
		uint2 tmp[8] = {
			{0xC0EE0B30,0x672990AF},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},
			{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828}
		};
	
		*(uint2x4*)&hash[ 0] = __ldg4((uint2x4*)&g_hash[(thread<<3) + 0]);
		*(uint2x4*)&hash[ 4] = __ldg4((uint2x4*)&g_hash[(thread<<3) + 4]);

		__syncthreads();

		#pragma unroll 8
		for(int i=0;i<8;i++)
			n[i]=hash[i];

		tmp[ 0]^= d_ROUND_ELT(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1);
		tmp[ 1]^= d_ROUND_ELT_LDG(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2);
		tmp[ 2]^= d_ROUND_ELT(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3);
		tmp[ 3]^= d_ROUND_ELT_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4);
		tmp[ 4]^= d_ROUND_ELT(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5);
		tmp[ 5]^= d_ROUND_ELT_LDG(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6);
		tmp[ 6]^= d_ROUND_ELT(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7);
		tmp[ 7]^= d_ROUND_ELT_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0);
		for (int i=1; i <10; i++){
			TRANSFER(n, tmp);
			tmp[ 0] = d_ROUND_ELT1_LDG(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, precomputed_round_key_64[(i-1)*8+0]);
			tmp[ 1] = d_ROUND_ELT1(    sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, precomputed_round_key_64[(i-1)*8+1]);
			tmp[ 2] = d_ROUND_ELT1(    sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, precomputed_round_key_64[(i-1)*8+2]);
			tmp[ 3] = d_ROUND_ELT1_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, precomputed_round_key_64[(i-1)*8+3]);
			tmp[ 4] = d_ROUND_ELT1(    sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, precomputed_round_key_64[(i-1)*8+4]);
			tmp[ 5] = d_ROUND_ELT1(    sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, precomputed_round_key_64[(i-1)*8+5]);
			tmp[ 6] = d_ROUND_ELT1(    sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, precomputed_round_key_64[(i-1)*8+6]);
			tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, precomputed_round_key_64[(i-1)*8+7]);
		}

		TRANSFER(h, tmp);
		#pragma unroll 8
		for (int i=0; i<8; i++)
			hash[ i] = h[i] = h[i] ^ hash[i];

		#pragma unroll 6
		for (int i=1; i<7; i++)
			n[i]=vectorize(0);

		n[0] = vectorize(0x80);
		n[7] = vectorize(0x2000000000000);

		#pragma unroll 8
		for (int i=0; i < 8; i++) {
			n[i] = n[i] ^ h[i];
		}

//		#pragma unroll 10
		for (int i=0; i < 10; i++) {
			tmp[ 0] = InitVector_RC[i];
			tmp[ 0]^= d_ROUND_ELT(sharedMemory, h, 0, 7, 6, 5, 4, 3, 2, 1);
			tmp[ 1] = d_ROUND_ELT(sharedMemory, h, 1, 0, 7, 6, 5, 4, 3, 2);
			tmp[ 2] = d_ROUND_ELT_LDG(sharedMemory, h, 2, 1, 0, 7, 6, 5, 4, 3);
			tmp[ 3] = d_ROUND_ELT(sharedMemory, h, 3, 2, 1, 0, 7, 6, 5, 4);
			tmp[ 4] = d_ROUND_ELT_LDG(sharedMemory, h, 4, 3, 2, 1, 0, 7, 6, 5);
			tmp[ 5] = d_ROUND_ELT(sharedMemory, h, 5, 4, 3, 2, 1, 0, 7, 6);
			tmp[ 6] = d_ROUND_ELT(sharedMemory, h, 6, 5, 4, 3, 2, 1, 0, 7);
			tmp[ 7] = d_ROUND_ELT(sharedMemory, h, 7, 6, 5, 4, 3, 2, 1, 0);
			TRANSFER(h, tmp);
			tmp[ 0] = d_ROUND_ELT1(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, tmp[0]);
			tmp[ 1] = d_ROUND_ELT1_LDG(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, tmp[1]);
			tmp[ 2] = d_ROUND_ELT1(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, tmp[2]);
			tmp[ 3] = d_ROUND_ELT1(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, tmp[3]);
			tmp[ 4] = d_ROUND_ELT1_LDG(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, tmp[4]);
			tmp[ 5] = d_ROUND_ELT1(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, tmp[5]);
			tmp[ 6] = d_ROUND_ELT1_LDG(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, tmp[6]);
			tmp[ 7] = d_ROUND_ELT1(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, tmp[7]);
			TRANSFER(n, tmp);
		}

		hash[0] = xor3x(hash[0], n[0], vectorize(0x80));
		hash[1] = hash[1]^ n[1];
		hash[2] = hash[2]^ n[2];
		hash[3] = hash[3]^ n[3];
		hash[4] = hash[4]^ n[4];
		hash[5] = hash[5]^ n[5];
		hash[6] = hash[6]^ n[6];
		hash[7] = xor3x(hash[7], n[7], vectorize(0x2000000000000));

		*(uint2x4*)&g_hash[(thread<<3)+ 0]    = *(uint2x4*)&hash[ 0];
		*(uint2x4*)&g_hash[(thread<<3)+ 4]    = *(uint2x4*)&hash[ 4];
	}
}

__host__
static void x15_whirlpool_cpu_hash_64(int thr_id, uint32_t threads, uint32_t *d_hash)
{
	dim3 grid((threads + TPB64-1) / TPB64);
	dim3 block(TPB64);

	x15_whirlpool_gpu_hash_64 <<<grid, block>>> (threads, (uint64_t*)d_hash);
}

__host__
void x15_whirlpool_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_nonceVector, uint32_t *d_hash, int order)
{
        x15_whirlpool_cpu_hash_64(thr_id, threads, d_hash);
}

__global__ __launch_bounds__(TPB64,2)
void x15_whirlpool_gpu_hash_64_final(uint32_t threads,const uint64_t* __restrict__ g_hash, uint32_t* resNonce, const uint64_t target)
{
	__shared__ uint2 sharedMemory[7][256];

	if (threadIdx.x < 256) {
		const uint2 tmp = __ldg((uint2*)&b0[threadIdx.x]);
		sharedMemory[0][threadIdx.x] = tmp;
		sharedMemory[1][threadIdx.x] = ROL8(tmp);
		sharedMemory[2][threadIdx.x] = ROL16(tmp);
		sharedMemory[3][threadIdx.x] = ROL24(tmp);
		sharedMemory[4][threadIdx.x] = SWAPUINT2(tmp);
		sharedMemory[5][threadIdx.x] = ROR24(tmp);
		sharedMemory[6][threadIdx.x] = ROR16(tmp);
	}

	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	if (thread < threads){

		uint2 hash[8], n[8], h[ 8], backup;
		uint2 tmp[8] = {
			{0xC0EE0B30,0x672990AF},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},
			{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828},{0x28282828,0x28282828}
		};
		
		*(uint2x4*)&hash[ 0] = __ldg4((uint2x4*)&g_hash[(thread<<3) + 0]);
		*(uint2x4*)&hash[ 4] = __ldg4((uint2x4*)&g_hash[(thread<<3) + 4]);

		__syncthreads();

		#pragma unroll 8
		for(int i=0;i<8;i++)
			n[i]=hash[i];

//		__syncthreads();

		tmp[ 0]^= d_ROUND_ELT(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1);
		tmp[ 1]^= d_ROUND_ELT_LDG(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2);
		tmp[ 2]^= d_ROUND_ELT(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3);
		tmp[ 3]^= d_ROUND_ELT_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4);
		tmp[ 4]^= d_ROUND_ELT(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5);
		tmp[ 5]^= d_ROUND_ELT_LDG(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6);
		tmp[ 6]^= d_ROUND_ELT(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7);
		tmp[ 7]^= d_ROUND_ELT_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0);

		for (int i=1; i <10; i++){
			TRANSFER(n, tmp);
			tmp[ 0] = d_ROUND_ELT1_LDG(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, precomputed_round_key_64[(i-1)*8+0]);
			tmp[ 1] = d_ROUND_ELT1(    sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, precomputed_round_key_64[(i-1)*8+1]);
			tmp[ 2] = d_ROUND_ELT1(    sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, precomputed_round_key_64[(i-1)*8+2]);
			tmp[ 3] = d_ROUND_ELT1_LDG(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, precomputed_round_key_64[(i-1)*8+3]);
			tmp[ 4] = d_ROUND_ELT1(    sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, precomputed_round_key_64[(i-1)*8+4]);
			tmp[ 5] = d_ROUND_ELT1(    sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, precomputed_round_key_64[(i-1)*8+5]);
			tmp[ 6] = d_ROUND_ELT1(    sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, precomputed_round_key_64[(i-1)*8+6]);
			tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, precomputed_round_key_64[(i-1)*8+7]);
		}

		TRANSFER(h, tmp);
		#pragma unroll 8
		for (int i=0; i<8; i++)
			h[i] = h[i] ^ hash[i];

		#pragma unroll 6
		for (int i=1; i<7; i++)
			n[i]=vectorize(0);

		n[0] = vectorize(0x80);
		n[7] = vectorize(0x2000000000000);

		#pragma unroll 8
		for (int i=0; i < 8; i++) {
			n[i] = n[i] ^ h[i];
		}
		
		backup = h[ 3];
		
//		#pragma unroll 8
		for (int i=0; i < 8; i++) {
			tmp[ 0] = d_ROUND_ELT1(sharedMemory, h, 0, 7, 6, 5, 4, 3, 2, 1, InitVector_RC[i]);
			tmp[ 1] = d_ROUND_ELT(sharedMemory, h, 1, 0, 7, 6, 5, 4, 3, 2);
			tmp[ 2] = d_ROUND_ELT_LDG(sharedMemory, h, 2, 1, 0, 7, 6, 5, 4, 3);
			tmp[ 3] = d_ROUND_ELT(sharedMemory, h, 3, 2, 1, 0, 7, 6, 5, 4);
			tmp[ 4] = d_ROUND_ELT_LDG(sharedMemory, h, 4, 3, 2, 1, 0, 7, 6, 5);
			tmp[ 5] = d_ROUND_ELT(sharedMemory, h, 5, 4, 3, 2, 1, 0, 7, 6);
			tmp[ 6] = d_ROUND_ELT_LDG(sharedMemory, h, 6, 5, 4, 3, 2, 1, 0, 7);
			tmp[ 7] = d_ROUND_ELT(sharedMemory, h, 7, 6, 5, 4, 3, 2, 1, 0);
			TRANSFER(h, tmp);
			tmp[ 0] = d_ROUND_ELT1(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, tmp[0]);
			tmp[ 1] = d_ROUND_ELT1(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, tmp[1]);
			tmp[ 2] = d_ROUND_ELT1_LDG(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, tmp[2]);
			tmp[ 3] = d_ROUND_ELT1(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, tmp[3]);
			tmp[ 4] = d_ROUND_ELT1(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, tmp[4]);
			tmp[ 5] = d_ROUND_ELT1(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, tmp[5]);
			tmp[ 6] = d_ROUND_ELT1(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, tmp[6]);
			tmp[ 7] = d_ROUND_ELT1_LDG(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, tmp[7]);
			TRANSFER(n, tmp);
		}
		tmp[ 0] = d_ROUND_ELT1(sharedMemory, h, 0, 7, 6, 5, 4, 3, 2, 1, InitVector_RC[8]);
		tmp[ 1] = d_ROUND_ELT(sharedMemory, h, 1, 0, 7, 6, 5, 4, 3, 2);
		tmp[ 2] = d_ROUND_ELT_LDG(sharedMemory, h, 2, 1, 0, 7, 6, 5, 4, 3);
		tmp[ 3] = d_ROUND_ELT(sharedMemory, h, 3, 2, 1, 0, 7, 6, 5, 4);
		tmp[ 4] = d_ROUND_ELT_LDG(sharedMemory, h, 4, 3, 2, 1, 0, 7, 6, 5);
		tmp[ 5] = d_ROUND_ELT(sharedMemory, h, 5, 4, 3, 2, 1, 0, 7, 6);
		tmp[ 6] = d_ROUND_ELT(sharedMemory, h, 6, 5, 4, 3, 2, 1, 0, 7);
		tmp[ 7] = d_ROUND_ELT(sharedMemory, h, 7, 6, 5, 4, 3, 2, 1, 0);
		TRANSFER(h, tmp);
		tmp[ 0] = d_ROUND_ELT1(sharedMemory,n, 0, 7, 6, 5, 4, 3, 2, 1, tmp[0]);
		tmp[ 1] = d_ROUND_ELT1(sharedMemory,n, 1, 0, 7, 6, 5, 4, 3, 2, tmp[1]);
		tmp[ 2] = d_ROUND_ELT1(sharedMemory,n, 2, 1, 0, 7, 6, 5, 4, 3, tmp[2]);
		tmp[ 3] = d_ROUND_ELT1(sharedMemory,n, 3, 2, 1, 0, 7, 6, 5, 4, tmp[3]);
		tmp[ 4] = d_ROUND_ELT1(sharedMemory,n, 4, 3, 2, 1, 0, 7, 6, 5, tmp[4]);
		tmp[ 5] = d_ROUND_ELT1(sharedMemory,n, 5, 4, 3, 2, 1, 0, 7, 6, tmp[5]);
		tmp[ 6] = d_ROUND_ELT1_LDG(sharedMemory,n, 6, 5, 4, 3, 2, 1, 0, 7, tmp[6]);
		tmp[ 7] = d_ROUND_ELT1(sharedMemory,n, 7, 6, 5, 4, 3, 2, 1, 0, tmp[7]);
		
		n[ 3] = backup ^ d_ROUND_ELT(sharedMemory,  h, 3, 2, 1, 0, 7, 6, 5, 4) ^ d_ROUND_ELT(sharedMemory,tmp, 3, 2, 1, 0, 7, 6, 5, 4);
		
		if(devectorize(n[3]) <= target){
			uint32_t tmp = atomicExch(&resNonce[0], thread);
			if (tmp != UINT32_MAX)
				resNonce[1] = tmp;		
		}
	}
}

void x15_whirlpool_cpu_hash_64_final(int thr_id, uint32_t threads, uint32_t *d_hash, uint32_t *d_resNonce, const uint64_t target)
{
	dim3 grid((threads + TPB64-1) / TPB64);
	dim3 block(TPB64);

	x15_whirlpool_gpu_hash_64_final <<<grid, block>>> (threads, (uint64_t*)d_hash,d_resNonce,target);
}

//======================================================

#define sph_u64 uint64_t


__constant__ static const sph_u64 pT0[256] = {
	SPH_C64(0xD83078C018601818), SPH_C64(0x2646AF05238C2323),
	SPH_C64(0xB891F97EC63FC6C6), SPH_C64(0xFBCD6F13E887E8E8),
	SPH_C64(0xCB13A14C87268787), SPH_C64(0x116D62A9B8DAB8B8),
	SPH_C64(0x0902050801040101), SPH_C64(0x0D9E6E424F214F4F),
	SPH_C64(0x9B6CEEAD36D83636), SPH_C64(0xFF510459A6A2A6A6),
	SPH_C64(0x0CB9BDDED26FD2D2), SPH_C64(0x0EF706FBF5F3F5F5),
	SPH_C64(0x96F280EF79F97979), SPH_C64(0x30DECE5F6FA16F6F),
	SPH_C64(0x6D3FEFFC917E9191), SPH_C64(0xF8A407AA52555252),
	SPH_C64(0x47C0FD27609D6060), SPH_C64(0x35657689BCCABCBC),
	SPH_C64(0x372BCDAC9B569B9B), SPH_C64(0x8A018C048E028E8E),
	SPH_C64(0xD25B1571A3B6A3A3), SPH_C64(0x6C183C600C300C0C),
	SPH_C64(0x84F68AFF7BF17B7B), SPH_C64(0x806AE1B535D43535),
	SPH_C64(0xF53A69E81D741D1D), SPH_C64(0xB3DD4753E0A7E0E0),
	SPH_C64(0x21B3ACF6D77BD7D7), SPH_C64(0x9C99ED5EC22FC2C2),
	SPH_C64(0x435C966D2EB82E2E), SPH_C64(0x29967A624B314B4B),
	SPH_C64(0x5DE121A3FEDFFEFE), SPH_C64(0xD5AE168257415757),
	SPH_C64(0xBD2A41A815541515), SPH_C64(0xE8EEB69F77C17777),
	SPH_C64(0x926EEBA537DC3737), SPH_C64(0x9ED7567BE5B3E5E5),
	SPH_C64(0x1323D98C9F469F9F), SPH_C64(0x23FD17D3F0E7F0F0),
	SPH_C64(0x20947F6A4A354A4A), SPH_C64(0x44A9959EDA4FDADA),
	SPH_C64(0xA2B025FA587D5858), SPH_C64(0xCF8FCA06C903C9C9),
	SPH_C64(0x7C528D5529A42929), SPH_C64(0x5A1422500A280A0A),
	SPH_C64(0x507F4FE1B1FEB1B1), SPH_C64(0xC95D1A69A0BAA0A0),
	SPH_C64(0x14D6DA7F6BB16B6B), SPH_C64(0xD917AB5C852E8585),
	SPH_C64(0x3C677381BDCEBDBD), SPH_C64(0x8FBA34D25D695D5D),
	SPH_C64(0x9020508010401010), SPH_C64(0x07F503F3F4F7F4F4),
	SPH_C64(0xDD8BC016CB0BCBCB), SPH_C64(0xD37CC6ED3EF83E3E),
	SPH_C64(0x2D0A112805140505), SPH_C64(0x78CEE61F67816767),
	SPH_C64(0x97D55373E4B7E4E4), SPH_C64(0x024EBB25279C2727),
	SPH_C64(0x7382583241194141), SPH_C64(0xA70B9D2C8B168B8B),
	SPH_C64(0xF6530151A7A6A7A7), SPH_C64(0xB2FA94CF7DE97D7D),
	SPH_C64(0x4937FBDC956E9595), SPH_C64(0x56AD9F8ED847D8D8),
	SPH_C64(0x70EB308BFBCBFBFB), SPH_C64(0xCDC17123EE9FEEEE),
	SPH_C64(0xBBF891C77CED7C7C), SPH_C64(0x71CCE31766856666),
	SPH_C64(0x7BA78EA6DD53DDDD), SPH_C64(0xAF2E4BB8175C1717),
	SPH_C64(0x458E460247014747), SPH_C64(0x1A21DC849E429E9E),
	SPH_C64(0xD489C51ECA0FCACA), SPH_C64(0x585A99752DB42D2D),
	SPH_C64(0x2E637991BFC6BFBF), SPH_C64(0x3F0E1B38071C0707),
	SPH_C64(0xAC472301AD8EADAD), SPH_C64(0xB0B42FEA5A755A5A),
	SPH_C64(0xEF1BB56C83368383), SPH_C64(0xB666FF8533CC3333),
	SPH_C64(0x5CC6F23F63916363), SPH_C64(0x12040A1002080202),
	SPH_C64(0x93493839AA92AAAA), SPH_C64(0xDEE2A8AF71D97171),
	SPH_C64(0xC68DCF0EC807C8C8), SPH_C64(0xD1327DC819641919),
	SPH_C64(0x3B92707249394949), SPH_C64(0x5FAF9A86D943D9D9),
	SPH_C64(0x31F91DC3F2EFF2F2), SPH_C64(0xA8DB484BE3ABE3E3),
	SPH_C64(0xB9B62AE25B715B5B), SPH_C64(0xBC0D9234881A8888),
	SPH_C64(0x3E29C8A49A529A9A), SPH_C64(0x0B4CBE2D26982626),
	SPH_C64(0xBF64FA8D32C83232), SPH_C64(0x597D4AE9B0FAB0B0),
	SPH_C64(0xF2CF6A1BE983E9E9), SPH_C64(0x771E33780F3C0F0F),
	SPH_C64(0x33B7A6E6D573D5D5), SPH_C64(0xF41DBA74803A8080),
	SPH_C64(0x27617C99BEC2BEBE), SPH_C64(0xEB87DE26CD13CDCD),
	SPH_C64(0x8968E4BD34D03434), SPH_C64(0x3290757A483D4848),
	SPH_C64(0x54E324ABFFDBFFFF), SPH_C64(0x8DF48FF77AF57A7A),
	SPH_C64(0x643DEAF4907A9090), SPH_C64(0x9DBE3EC25F615F5F),
	SPH_C64(0x3D40A01D20802020), SPH_C64(0x0FD0D56768BD6868),
	SPH_C64(0xCA3472D01A681A1A), SPH_C64(0xB7412C19AE82AEAE),
	SPH_C64(0x7D755EC9B4EAB4B4), SPH_C64(0xCEA8199A544D5454),
	SPH_C64(0x7F3BE5EC93769393), SPH_C64(0x2F44AA0D22882222),
	SPH_C64(0x63C8E907648D6464), SPH_C64(0x2AFF12DBF1E3F1F1),
	SPH_C64(0xCCE6A2BF73D17373), SPH_C64(0x82245A9012481212),
	SPH_C64(0x7A805D3A401D4040), SPH_C64(0x4810284008200808),
	SPH_C64(0x959BE856C32BC3C3), SPH_C64(0xDFC57B33EC97ECEC),
	SPH_C64(0x4DAB9096DB4BDBDB), SPH_C64(0xC05F1F61A1BEA1A1),
	SPH_C64(0x9107831C8D0E8D8D), SPH_C64(0xC87AC9F53DF43D3D),
	SPH_C64(0x5B33F1CC97669797), SPH_C64(0x0000000000000000),
	SPH_C64(0xF983D436CF1BCFCF), SPH_C64(0x6E5687452BAC2B2B),
	SPH_C64(0xE1ECB39776C57676), SPH_C64(0xE619B06482328282),
	SPH_C64(0x28B1A9FED67FD6D6), SPH_C64(0xC33677D81B6C1B1B),
	SPH_C64(0x74775BC1B5EEB5B5), SPH_C64(0xBE432911AF86AFAF),
	SPH_C64(0x1DD4DF776AB56A6A), SPH_C64(0xEAA00DBA505D5050),
	SPH_C64(0x578A4C1245094545), SPH_C64(0x38FB18CBF3EBF3F3),
	SPH_C64(0xAD60F09D30C03030), SPH_C64(0xC4C3742BEF9BEFEF),
	SPH_C64(0xDA7EC3E53FFC3F3F), SPH_C64(0xC7AA1C9255495555),
	SPH_C64(0xDB591079A2B2A2A2), SPH_C64(0xE9C96503EA8FEAEA),
	SPH_C64(0x6ACAEC0F65896565), SPH_C64(0x036968B9BAD2BABA),
	SPH_C64(0x4A5E93652FBC2F2F), SPH_C64(0x8E9DE74EC027C0C0),
	SPH_C64(0x60A181BEDE5FDEDE), SPH_C64(0xFC386CE01C701C1C),
	SPH_C64(0x46E72EBBFDD3FDFD), SPH_C64(0x1F9A64524D294D4D),
	SPH_C64(0x7639E0E492729292), SPH_C64(0xFAEABC8F75C97575),
	SPH_C64(0x360C1E3006180606), SPH_C64(0xAE0998248A128A8A),
	SPH_C64(0x4B7940F9B2F2B2B2), SPH_C64(0x85D15963E6BFE6E6),
	SPH_C64(0x7E1C36700E380E0E), SPH_C64(0xE73E63F81F7C1F1F),
	SPH_C64(0x55C4F73762956262), SPH_C64(0x3AB5A3EED477D4D4),
	SPH_C64(0x814D3229A89AA8A8), SPH_C64(0x5231F4C496629696),
	SPH_C64(0x62EF3A9BF9C3F9F9), SPH_C64(0xA397F666C533C5C5),
	SPH_C64(0x104AB13525942525), SPH_C64(0xABB220F259795959),
	SPH_C64(0xD015AE54842A8484), SPH_C64(0xC5E4A7B772D57272),
	SPH_C64(0xEC72DDD539E43939), SPH_C64(0x1698615A4C2D4C4C),
	SPH_C64(0x94BC3BCA5E655E5E), SPH_C64(0x9FF085E778FD7878),
	SPH_C64(0xE570D8DD38E03838), SPH_C64(0x980586148C0A8C8C),
	SPH_C64(0x17BFB2C6D163D1D1), SPH_C64(0xE4570B41A5AEA5A5),
	SPH_C64(0xA1D94D43E2AFE2E2), SPH_C64(0x4EC2F82F61996161),
	SPH_C64(0x427B45F1B3F6B3B3), SPH_C64(0x3442A51521842121),
	SPH_C64(0x0825D6949C4A9C9C), SPH_C64(0xEE3C66F01E781E1E),
	SPH_C64(0x6186522243114343), SPH_C64(0xB193FC76C73BC7C7),
	SPH_C64(0x4FE52BB3FCD7FCFC), SPH_C64(0x2408142004100404),
	SPH_C64(0xE3A208B251595151), SPH_C64(0x252FC7BC995E9999),
	SPH_C64(0x22DAC44F6DA96D6D), SPH_C64(0x651A39680D340D0D),
	SPH_C64(0x79E93583FACFFAFA), SPH_C64(0x69A384B6DF5BDFDF),
	SPH_C64(0xA9FC9BD77EE57E7E), SPH_C64(0x1948B43D24902424),
	SPH_C64(0xFE76D7C53BEC3B3B), SPH_C64(0x9A4B3D31AB96ABAB),
	SPH_C64(0xF081D13ECE1FCECE), SPH_C64(0x9922558811441111),
	SPH_C64(0x8303890C8F068F8F), SPH_C64(0x049C6B4A4E254E4E),
	SPH_C64(0x667351D1B7E6B7B7), SPH_C64(0xE0CB600BEB8BEBEB),
	SPH_C64(0xC178CCFD3CF03C3C), SPH_C64(0xFD1FBF7C813E8181),
	SPH_C64(0x4035FED4946A9494), SPH_C64(0x1CF30CEBF7FBF7F7),
	SPH_C64(0x186F67A1B9DEB9B9), SPH_C64(0x8B265F98134C1313),
	SPH_C64(0x51589C7D2CB02C2C), SPH_C64(0x05BBB8D6D36BD3D3),
	SPH_C64(0x8CD35C6BE7BBE7E7), SPH_C64(0x39DCCB576EA56E6E),
	SPH_C64(0xAA95F36EC437C4C4), SPH_C64(0x1B060F18030C0303),
	SPH_C64(0xDCAC138A56455656), SPH_C64(0x5E88491A440D4444),
	SPH_C64(0xA0FE9EDF7FE17F7F), SPH_C64(0x884F3721A99EA9A9),
	SPH_C64(0x6754824D2AA82A2A), SPH_C64(0x0A6B6DB1BBD6BBBB),
	SPH_C64(0x879FE246C123C1C1), SPH_C64(0xF1A602A253515353),
	SPH_C64(0x72A58BAEDC57DCDC), SPH_C64(0x531627580B2C0B0B),
	SPH_C64(0x0127D39C9D4E9D9D), SPH_C64(0x2BD8C1476CAD6C6C),
	SPH_C64(0xA462F59531C43131), SPH_C64(0xF3E8B98774CD7474),
	SPH_C64(0x15F109E3F6FFF6F6), SPH_C64(0x4C8C430A46054646),
	SPH_C64(0xA5452609AC8AACAC), SPH_C64(0xB50F973C891E8989),
	SPH_C64(0xB42844A014501414), SPH_C64(0xBADF425BE1A3E1E1),
	SPH_C64(0xA62C4EB016581616), SPH_C64(0xF774D2CD3AE83A3A),
	SPH_C64(0x06D2D06F69B96969), SPH_C64(0x41122D4809240909),
	SPH_C64(0xD7E0ADA770DD7070), SPH_C64(0x6F7154D9B6E2B6B6),
	SPH_C64(0x1EBDB7CED067D0D0), SPH_C64(0xD6C77E3BED93EDED),
	SPH_C64(0xE285DB2ECC17CCCC), SPH_C64(0x6884572A42154242),
	SPH_C64(0x2C2DC2B4985A9898), SPH_C64(0xED550E49A4AAA4A4),
	SPH_C64(0x7550885D28A02828), SPH_C64(0x86B831DA5C6D5C5C),
	SPH_C64(0x6BED3F93F8C7F8F8), SPH_C64(0xC211A44486228686)
};

__constant__ static const sph_u64 pT1[256] = {
	SPH_C64(0x3078C018601818D8), SPH_C64(0x46AF05238C232326),
	SPH_C64(0x91F97EC63FC6C6B8), SPH_C64(0xCD6F13E887E8E8FB),
	SPH_C64(0x13A14C87268787CB), SPH_C64(0x6D62A9B8DAB8B811),
	SPH_C64(0x0205080104010109), SPH_C64(0x9E6E424F214F4F0D),
	SPH_C64(0x6CEEAD36D836369B), SPH_C64(0x510459A6A2A6A6FF),
	SPH_C64(0xB9BDDED26FD2D20C), SPH_C64(0xF706FBF5F3F5F50E),
	SPH_C64(0xF280EF79F9797996), SPH_C64(0xDECE5F6FA16F6F30),
	SPH_C64(0x3FEFFC917E91916D), SPH_C64(0xA407AA52555252F8),
	SPH_C64(0xC0FD27609D606047), SPH_C64(0x657689BCCABCBC35),
	SPH_C64(0x2BCDAC9B569B9B37), SPH_C64(0x018C048E028E8E8A),
	SPH_C64(0x5B1571A3B6A3A3D2), SPH_C64(0x183C600C300C0C6C),
	SPH_C64(0xF68AFF7BF17B7B84), SPH_C64(0x6AE1B535D4353580),
	SPH_C64(0x3A69E81D741D1DF5), SPH_C64(0xDD4753E0A7E0E0B3),
	SPH_C64(0xB3ACF6D77BD7D721), SPH_C64(0x99ED5EC22FC2C29C),
	SPH_C64(0x5C966D2EB82E2E43), SPH_C64(0x967A624B314B4B29),
	SPH_C64(0xE121A3FEDFFEFE5D), SPH_C64(0xAE168257415757D5),
	SPH_C64(0x2A41A815541515BD), SPH_C64(0xEEB69F77C17777E8),
	SPH_C64(0x6EEBA537DC373792), SPH_C64(0xD7567BE5B3E5E59E),
	SPH_C64(0x23D98C9F469F9F13), SPH_C64(0xFD17D3F0E7F0F023),
	SPH_C64(0x947F6A4A354A4A20), SPH_C64(0xA9959EDA4FDADA44),
	SPH_C64(0xB025FA587D5858A2), SPH_C64(0x8FCA06C903C9C9CF),
	SPH_C64(0x528D5529A429297C), SPH_C64(0x1422500A280A0A5A),
	SPH_C64(0x7F4FE1B1FEB1B150), SPH_C64(0x5D1A69A0BAA0A0C9),
	SPH_C64(0xD6DA7F6BB16B6B14), SPH_C64(0x17AB5C852E8585D9),
	SPH_C64(0x677381BDCEBDBD3C), SPH_C64(0xBA34D25D695D5D8F),
	SPH_C64(0x2050801040101090), SPH_C64(0xF503F3F4F7F4F407),
	SPH_C64(0x8BC016CB0BCBCBDD), SPH_C64(0x7CC6ED3EF83E3ED3),
	SPH_C64(0x0A1128051405052D), SPH_C64(0xCEE61F6781676778),
	SPH_C64(0xD55373E4B7E4E497), SPH_C64(0x4EBB25279C272702),
	SPH_C64(0x8258324119414173), SPH_C64(0x0B9D2C8B168B8BA7),
	SPH_C64(0x530151A7A6A7A7F6), SPH_C64(0xFA94CF7DE97D7DB2),
	SPH_C64(0x37FBDC956E959549), SPH_C64(0xAD9F8ED847D8D856),
	SPH_C64(0xEB308BFBCBFBFB70), SPH_C64(0xC17123EE9FEEEECD),
	SPH_C64(0xF891C77CED7C7CBB), SPH_C64(0xCCE3176685666671),
	SPH_C64(0xA78EA6DD53DDDD7B), SPH_C64(0x2E4BB8175C1717AF),
	SPH_C64(0x8E46024701474745), SPH_C64(0x21DC849E429E9E1A),
	SPH_C64(0x89C51ECA0FCACAD4), SPH_C64(0x5A99752DB42D2D58),
	SPH_C64(0x637991BFC6BFBF2E), SPH_C64(0x0E1B38071C07073F),
	SPH_C64(0x472301AD8EADADAC), SPH_C64(0xB42FEA5A755A5AB0),
	SPH_C64(0x1BB56C83368383EF), SPH_C64(0x66FF8533CC3333B6),
	SPH_C64(0xC6F23F639163635C), SPH_C64(0x040A100208020212),
	SPH_C64(0x493839AA92AAAA93), SPH_C64(0xE2A8AF71D97171DE),
	SPH_C64(0x8DCF0EC807C8C8C6), SPH_C64(0x327DC819641919D1),
	SPH_C64(0x927072493949493B), SPH_C64(0xAF9A86D943D9D95F),
	SPH_C64(0xF91DC3F2EFF2F231), SPH_C64(0xDB484BE3ABE3E3A8),
	SPH_C64(0xB62AE25B715B5BB9), SPH_C64(0x0D9234881A8888BC),
	SPH_C64(0x29C8A49A529A9A3E), SPH_C64(0x4CBE2D269826260B),
	SPH_C64(0x64FA8D32C83232BF), SPH_C64(0x7D4AE9B0FAB0B059),
	SPH_C64(0xCF6A1BE983E9E9F2), SPH_C64(0x1E33780F3C0F0F77),
	SPH_C64(0xB7A6E6D573D5D533), SPH_C64(0x1DBA74803A8080F4),
	SPH_C64(0x617C99BEC2BEBE27), SPH_C64(0x87DE26CD13CDCDEB),
	SPH_C64(0x68E4BD34D0343489), SPH_C64(0x90757A483D484832),
	SPH_C64(0xE324ABFFDBFFFF54), SPH_C64(0xF48FF77AF57A7A8D),
	SPH_C64(0x3DEAF4907A909064), SPH_C64(0xBE3EC25F615F5F9D),
	SPH_C64(0x40A01D208020203D), SPH_C64(0xD0D56768BD68680F),
	SPH_C64(0x3472D01A681A1ACA), SPH_C64(0x412C19AE82AEAEB7),
	SPH_C64(0x755EC9B4EAB4B47D), SPH_C64(0xA8199A544D5454CE),
	SPH_C64(0x3BE5EC937693937F), SPH_C64(0x44AA0D228822222F),
	SPH_C64(0xC8E907648D646463), SPH_C64(0xFF12DBF1E3F1F12A),
	SPH_C64(0xE6A2BF73D17373CC), SPH_C64(0x245A901248121282),
	SPH_C64(0x805D3A401D40407A), SPH_C64(0x1028400820080848),
	SPH_C64(0x9BE856C32BC3C395), SPH_C64(0xC57B33EC97ECECDF),
	SPH_C64(0xAB9096DB4BDBDB4D), SPH_C64(0x5F1F61A1BEA1A1C0),
	SPH_C64(0x07831C8D0E8D8D91), SPH_C64(0x7AC9F53DF43D3DC8),
	SPH_C64(0x33F1CC976697975B), SPH_C64(0x0000000000000000),
	SPH_C64(0x83D436CF1BCFCFF9), SPH_C64(0x5687452BAC2B2B6E),
	SPH_C64(0xECB39776C57676E1), SPH_C64(0x19B06482328282E6),
	SPH_C64(0xB1A9FED67FD6D628), SPH_C64(0x3677D81B6C1B1BC3),
	SPH_C64(0x775BC1B5EEB5B574), SPH_C64(0x432911AF86AFAFBE),
	SPH_C64(0xD4DF776AB56A6A1D), SPH_C64(0xA00DBA505D5050EA),
	SPH_C64(0x8A4C124509454557), SPH_C64(0xFB18CBF3EBF3F338),
	SPH_C64(0x60F09D30C03030AD), SPH_C64(0xC3742BEF9BEFEFC4),
	SPH_C64(0x7EC3E53FFC3F3FDA), SPH_C64(0xAA1C9255495555C7),
	SPH_C64(0x591079A2B2A2A2DB), SPH_C64(0xC96503EA8FEAEAE9),
	SPH_C64(0xCAEC0F658965656A), SPH_C64(0x6968B9BAD2BABA03),
	SPH_C64(0x5E93652FBC2F2F4A), SPH_C64(0x9DE74EC027C0C08E),
	SPH_C64(0xA181BEDE5FDEDE60), SPH_C64(0x386CE01C701C1CFC),
	SPH_C64(0xE72EBBFDD3FDFD46), SPH_C64(0x9A64524D294D4D1F),
	SPH_C64(0x39E0E49272929276), SPH_C64(0xEABC8F75C97575FA),
	SPH_C64(0x0C1E300618060636), SPH_C64(0x0998248A128A8AAE),
	SPH_C64(0x7940F9B2F2B2B24B), SPH_C64(0xD15963E6BFE6E685),
	SPH_C64(0x1C36700E380E0E7E), SPH_C64(0x3E63F81F7C1F1FE7),
	SPH_C64(0xC4F7376295626255), SPH_C64(0xB5A3EED477D4D43A),
	SPH_C64(0x4D3229A89AA8A881), SPH_C64(0x31F4C49662969652),
	SPH_C64(0xEF3A9BF9C3F9F962), SPH_C64(0x97F666C533C5C5A3),
	SPH_C64(0x4AB1352594252510), SPH_C64(0xB220F259795959AB),
	SPH_C64(0x15AE54842A8484D0), SPH_C64(0xE4A7B772D57272C5),
	SPH_C64(0x72DDD539E43939EC), SPH_C64(0x98615A4C2D4C4C16),
	SPH_C64(0xBC3BCA5E655E5E94), SPH_C64(0xF085E778FD78789F),
	SPH_C64(0x70D8DD38E03838E5), SPH_C64(0x0586148C0A8C8C98),
	SPH_C64(0xBFB2C6D163D1D117), SPH_C64(0x570B41A5AEA5A5E4),
	SPH_C64(0xD94D43E2AFE2E2A1), SPH_C64(0xC2F82F619961614E),
	SPH_C64(0x7B45F1B3F6B3B342), SPH_C64(0x42A5152184212134),
	SPH_C64(0x25D6949C4A9C9C08), SPH_C64(0x3C66F01E781E1EEE),
	SPH_C64(0x8652224311434361), SPH_C64(0x93FC76C73BC7C7B1),
	SPH_C64(0xE52BB3FCD7FCFC4F), SPH_C64(0x0814200410040424),
	SPH_C64(0xA208B251595151E3), SPH_C64(0x2FC7BC995E999925),
	SPH_C64(0xDAC44F6DA96D6D22), SPH_C64(0x1A39680D340D0D65),
	SPH_C64(0xE93583FACFFAFA79), SPH_C64(0xA384B6DF5BDFDF69),
	SPH_C64(0xFC9BD77EE57E7EA9), SPH_C64(0x48B43D2490242419),
	SPH_C64(0x76D7C53BEC3B3BFE), SPH_C64(0x4B3D31AB96ABAB9A),
	SPH_C64(0x81D13ECE1FCECEF0), SPH_C64(0x2255881144111199),
	SPH_C64(0x03890C8F068F8F83), SPH_C64(0x9C6B4A4E254E4E04),
	SPH_C64(0x7351D1B7E6B7B766), SPH_C64(0xCB600BEB8BEBEBE0),
	SPH_C64(0x78CCFD3CF03C3CC1), SPH_C64(0x1FBF7C813E8181FD),
	SPH_C64(0x35FED4946A949440), SPH_C64(0xF30CEBF7FBF7F71C),
	SPH_C64(0x6F67A1B9DEB9B918), SPH_C64(0x265F98134C13138B),
	SPH_C64(0x589C7D2CB02C2C51), SPH_C64(0xBBB8D6D36BD3D305),
	SPH_C64(0xD35C6BE7BBE7E78C), SPH_C64(0xDCCB576EA56E6E39),
	SPH_C64(0x95F36EC437C4C4AA), SPH_C64(0x060F18030C03031B),
	SPH_C64(0xAC138A56455656DC), SPH_C64(0x88491A440D44445E),
	SPH_C64(0xFE9EDF7FE17F7FA0), SPH_C64(0x4F3721A99EA9A988),
	SPH_C64(0x54824D2AA82A2A67), SPH_C64(0x6B6DB1BBD6BBBB0A),
	SPH_C64(0x9FE246C123C1C187), SPH_C64(0xA602A253515353F1),
	SPH_C64(0xA58BAEDC57DCDC72), SPH_C64(0x1627580B2C0B0B53),
	SPH_C64(0x27D39C9D4E9D9D01), SPH_C64(0xD8C1476CAD6C6C2B),
	SPH_C64(0x62F59531C43131A4), SPH_C64(0xE8B98774CD7474F3),
	SPH_C64(0xF109E3F6FFF6F615), SPH_C64(0x8C430A460546464C),
	SPH_C64(0x452609AC8AACACA5), SPH_C64(0x0F973C891E8989B5),
	SPH_C64(0x2844A014501414B4), SPH_C64(0xDF425BE1A3E1E1BA),
	SPH_C64(0x2C4EB016581616A6), SPH_C64(0x74D2CD3AE83A3AF7),
	SPH_C64(0xD2D06F69B9696906), SPH_C64(0x122D480924090941),
	SPH_C64(0xE0ADA770DD7070D7), SPH_C64(0x7154D9B6E2B6B66F),
	SPH_C64(0xBDB7CED067D0D01E), SPH_C64(0xC77E3BED93EDEDD6),
	SPH_C64(0x85DB2ECC17CCCCE2), SPH_C64(0x84572A4215424268),
	SPH_C64(0x2DC2B4985A98982C), SPH_C64(0x550E49A4AAA4A4ED),
	SPH_C64(0x50885D28A0282875), SPH_C64(0xB831DA5C6D5C5C86),
	SPH_C64(0xED3F93F8C7F8F86B), SPH_C64(0x11A44486228686C2)
};

__constant__ static const sph_u64 pT2[256] = {
	SPH_C64(0x78C018601818D830), SPH_C64(0xAF05238C23232646),
	SPH_C64(0xF97EC63FC6C6B891), SPH_C64(0x6F13E887E8E8FBCD),
	SPH_C64(0xA14C87268787CB13), SPH_C64(0x62A9B8DAB8B8116D),
	SPH_C64(0x0508010401010902), SPH_C64(0x6E424F214F4F0D9E),
	SPH_C64(0xEEAD36D836369B6C), SPH_C64(0x0459A6A2A6A6FF51),
	SPH_C64(0xBDDED26FD2D20CB9), SPH_C64(0x06FBF5F3F5F50EF7),
	SPH_C64(0x80EF79F9797996F2), SPH_C64(0xCE5F6FA16F6F30DE),
	SPH_C64(0xEFFC917E91916D3F), SPH_C64(0x07AA52555252F8A4),
	SPH_C64(0xFD27609D606047C0), SPH_C64(0x7689BCCABCBC3565),
	SPH_C64(0xCDAC9B569B9B372B), SPH_C64(0x8C048E028E8E8A01),
	SPH_C64(0x1571A3B6A3A3D25B), SPH_C64(0x3C600C300C0C6C18),
	SPH_C64(0x8AFF7BF17B7B84F6), SPH_C64(0xE1B535D43535806A),
	SPH_C64(0x69E81D741D1DF53A), SPH_C64(0x4753E0A7E0E0B3DD),
	SPH_C64(0xACF6D77BD7D721B3), SPH_C64(0xED5EC22FC2C29C99),
	SPH_C64(0x966D2EB82E2E435C), SPH_C64(0x7A624B314B4B2996),
	SPH_C64(0x21A3FEDFFEFE5DE1), SPH_C64(0x168257415757D5AE),
	SPH_C64(0x41A815541515BD2A), SPH_C64(0xB69F77C17777E8EE),
	SPH_C64(0xEBA537DC3737926E), SPH_C64(0x567BE5B3E5E59ED7),
	SPH_C64(0xD98C9F469F9F1323), SPH_C64(0x17D3F0E7F0F023FD),
	SPH_C64(0x7F6A4A354A4A2094), SPH_C64(0x959EDA4FDADA44A9),
	SPH_C64(0x25FA587D5858A2B0), SPH_C64(0xCA06C903C9C9CF8F),
	SPH_C64(0x8D5529A429297C52), SPH_C64(0x22500A280A0A5A14),
	SPH_C64(0x4FE1B1FEB1B1507F), SPH_C64(0x1A69A0BAA0A0C95D),
	SPH_C64(0xDA7F6BB16B6B14D6), SPH_C64(0xAB5C852E8585D917),
	SPH_C64(0x7381BDCEBDBD3C67), SPH_C64(0x34D25D695D5D8FBA),
	SPH_C64(0x5080104010109020), SPH_C64(0x03F3F4F7F4F407F5),
	SPH_C64(0xC016CB0BCBCBDD8B), SPH_C64(0xC6ED3EF83E3ED37C),
	SPH_C64(0x1128051405052D0A), SPH_C64(0xE61F6781676778CE),
	SPH_C64(0x5373E4B7E4E497D5), SPH_C64(0xBB25279C2727024E),
	SPH_C64(0x5832411941417382), SPH_C64(0x9D2C8B168B8BA70B),
	SPH_C64(0x0151A7A6A7A7F653), SPH_C64(0x94CF7DE97D7DB2FA),
	SPH_C64(0xFBDC956E95954937), SPH_C64(0x9F8ED847D8D856AD),
	SPH_C64(0x308BFBCBFBFB70EB), SPH_C64(0x7123EE9FEEEECDC1),
	SPH_C64(0x91C77CED7C7CBBF8), SPH_C64(0xE3176685666671CC),
	SPH_C64(0x8EA6DD53DDDD7BA7), SPH_C64(0x4BB8175C1717AF2E),
	SPH_C64(0x460247014747458E), SPH_C64(0xDC849E429E9E1A21),
	SPH_C64(0xC51ECA0FCACAD489), SPH_C64(0x99752DB42D2D585A),
	SPH_C64(0x7991BFC6BFBF2E63), SPH_C64(0x1B38071C07073F0E),
	SPH_C64(0x2301AD8EADADAC47), SPH_C64(0x2FEA5A755A5AB0B4),
	SPH_C64(0xB56C83368383EF1B), SPH_C64(0xFF8533CC3333B666),
	SPH_C64(0xF23F639163635CC6), SPH_C64(0x0A10020802021204),
	SPH_C64(0x3839AA92AAAA9349), SPH_C64(0xA8AF71D97171DEE2),
	SPH_C64(0xCF0EC807C8C8C68D), SPH_C64(0x7DC819641919D132),
	SPH_C64(0x7072493949493B92), SPH_C64(0x9A86D943D9D95FAF),
	SPH_C64(0x1DC3F2EFF2F231F9), SPH_C64(0x484BE3ABE3E3A8DB),
	SPH_C64(0x2AE25B715B5BB9B6), SPH_C64(0x9234881A8888BC0D),
	SPH_C64(0xC8A49A529A9A3E29), SPH_C64(0xBE2D269826260B4C),
	SPH_C64(0xFA8D32C83232BF64), SPH_C64(0x4AE9B0FAB0B0597D),
	SPH_C64(0x6A1BE983E9E9F2CF), SPH_C64(0x33780F3C0F0F771E),
	SPH_C64(0xA6E6D573D5D533B7), SPH_C64(0xBA74803A8080F41D),
	SPH_C64(0x7C99BEC2BEBE2761), SPH_C64(0xDE26CD13CDCDEB87),
	SPH_C64(0xE4BD34D034348968), SPH_C64(0x757A483D48483290),
	SPH_C64(0x24ABFFDBFFFF54E3), SPH_C64(0x8FF77AF57A7A8DF4),
	SPH_C64(0xEAF4907A9090643D), SPH_C64(0x3EC25F615F5F9DBE),
	SPH_C64(0xA01D208020203D40), SPH_C64(0xD56768BD68680FD0),
	SPH_C64(0x72D01A681A1ACA34), SPH_C64(0x2C19AE82AEAEB741),
	SPH_C64(0x5EC9B4EAB4B47D75), SPH_C64(0x199A544D5454CEA8),
	SPH_C64(0xE5EC937693937F3B), SPH_C64(0xAA0D228822222F44),
	SPH_C64(0xE907648D646463C8), SPH_C64(0x12DBF1E3F1F12AFF),
	SPH_C64(0xA2BF73D17373CCE6), SPH_C64(0x5A90124812128224),
	SPH_C64(0x5D3A401D40407A80), SPH_C64(0x2840082008084810),
	SPH_C64(0xE856C32BC3C3959B), SPH_C64(0x7B33EC97ECECDFC5),
	SPH_C64(0x9096DB4BDBDB4DAB), SPH_C64(0x1F61A1BEA1A1C05F),
	SPH_C64(0x831C8D0E8D8D9107), SPH_C64(0xC9F53DF43D3DC87A),
	SPH_C64(0xF1CC976697975B33), SPH_C64(0x0000000000000000),
	SPH_C64(0xD436CF1BCFCFF983), SPH_C64(0x87452BAC2B2B6E56),
	SPH_C64(0xB39776C57676E1EC), SPH_C64(0xB06482328282E619),
	SPH_C64(0xA9FED67FD6D628B1), SPH_C64(0x77D81B6C1B1BC336),
	SPH_C64(0x5BC1B5EEB5B57477), SPH_C64(0x2911AF86AFAFBE43),
	SPH_C64(0xDF776AB56A6A1DD4), SPH_C64(0x0DBA505D5050EAA0),
	SPH_C64(0x4C1245094545578A), SPH_C64(0x18CBF3EBF3F338FB),
	SPH_C64(0xF09D30C03030AD60), SPH_C64(0x742BEF9BEFEFC4C3),
	SPH_C64(0xC3E53FFC3F3FDA7E), SPH_C64(0x1C9255495555C7AA),
	SPH_C64(0x1079A2B2A2A2DB59), SPH_C64(0x6503EA8FEAEAE9C9),
	SPH_C64(0xEC0F658965656ACA), SPH_C64(0x68B9BAD2BABA0369),
	SPH_C64(0x93652FBC2F2F4A5E), SPH_C64(0xE74EC027C0C08E9D),
	SPH_C64(0x81BEDE5FDEDE60A1), SPH_C64(0x6CE01C701C1CFC38),
	SPH_C64(0x2EBBFDD3FDFD46E7), SPH_C64(0x64524D294D4D1F9A),
	SPH_C64(0xE0E4927292927639), SPH_C64(0xBC8F75C97575FAEA),
	SPH_C64(0x1E3006180606360C), SPH_C64(0x98248A128A8AAE09),
	SPH_C64(0x40F9B2F2B2B24B79), SPH_C64(0x5963E6BFE6E685D1),
	SPH_C64(0x36700E380E0E7E1C), SPH_C64(0x63F81F7C1F1FE73E),
	SPH_C64(0xF7376295626255C4), SPH_C64(0xA3EED477D4D43AB5),
	SPH_C64(0x3229A89AA8A8814D), SPH_C64(0xF4C4966296965231),
	SPH_C64(0x3A9BF9C3F9F962EF), SPH_C64(0xF666C533C5C5A397),
	SPH_C64(0xB13525942525104A), SPH_C64(0x20F259795959ABB2),
	SPH_C64(0xAE54842A8484D015), SPH_C64(0xA7B772D57272C5E4),
	SPH_C64(0xDDD539E43939EC72), SPH_C64(0x615A4C2D4C4C1698),
	SPH_C64(0x3BCA5E655E5E94BC), SPH_C64(0x85E778FD78789FF0),
	SPH_C64(0xD8DD38E03838E570), SPH_C64(0x86148C0A8C8C9805),
	SPH_C64(0xB2C6D163D1D117BF), SPH_C64(0x0B41A5AEA5A5E457),
	SPH_C64(0x4D43E2AFE2E2A1D9), SPH_C64(0xF82F619961614EC2),
	SPH_C64(0x45F1B3F6B3B3427B), SPH_C64(0xA515218421213442),
	SPH_C64(0xD6949C4A9C9C0825), SPH_C64(0x66F01E781E1EEE3C),
	SPH_C64(0x5222431143436186), SPH_C64(0xFC76C73BC7C7B193),
	SPH_C64(0x2BB3FCD7FCFC4FE5), SPH_C64(0x1420041004042408),
	SPH_C64(0x08B251595151E3A2), SPH_C64(0xC7BC995E9999252F),
	SPH_C64(0xC44F6DA96D6D22DA), SPH_C64(0x39680D340D0D651A),
	SPH_C64(0x3583FACFFAFA79E9), SPH_C64(0x84B6DF5BDFDF69A3),
	SPH_C64(0x9BD77EE57E7EA9FC), SPH_C64(0xB43D249024241948),
	SPH_C64(0xD7C53BEC3B3BFE76), SPH_C64(0x3D31AB96ABAB9A4B),
	SPH_C64(0xD13ECE1FCECEF081), SPH_C64(0x5588114411119922),
	SPH_C64(0x890C8F068F8F8303), SPH_C64(0x6B4A4E254E4E049C),
	SPH_C64(0x51D1B7E6B7B76673), SPH_C64(0x600BEB8BEBEBE0CB),
	SPH_C64(0xCCFD3CF03C3CC178), SPH_C64(0xBF7C813E8181FD1F),
	SPH_C64(0xFED4946A94944035), SPH_C64(0x0CEBF7FBF7F71CF3),
	SPH_C64(0x67A1B9DEB9B9186F), SPH_C64(0x5F98134C13138B26),
	SPH_C64(0x9C7D2CB02C2C5158), SPH_C64(0xB8D6D36BD3D305BB),
	SPH_C64(0x5C6BE7BBE7E78CD3), SPH_C64(0xCB576EA56E6E39DC),
	SPH_C64(0xF36EC437C4C4AA95), SPH_C64(0x0F18030C03031B06),
	SPH_C64(0x138A56455656DCAC), SPH_C64(0x491A440D44445E88),
	SPH_C64(0x9EDF7FE17F7FA0FE), SPH_C64(0x3721A99EA9A9884F),
	SPH_C64(0x824D2AA82A2A6754), SPH_C64(0x6DB1BBD6BBBB0A6B),
	SPH_C64(0xE246C123C1C1879F), SPH_C64(0x02A253515353F1A6),
	SPH_C64(0x8BAEDC57DCDC72A5), SPH_C64(0x27580B2C0B0B5316),
	SPH_C64(0xD39C9D4E9D9D0127), SPH_C64(0xC1476CAD6C6C2BD8),
	SPH_C64(0xF59531C43131A462), SPH_C64(0xB98774CD7474F3E8),
	SPH_C64(0x09E3F6FFF6F615F1), SPH_C64(0x430A460546464C8C),
	SPH_C64(0x2609AC8AACACA545), SPH_C64(0x973C891E8989B50F),
	SPH_C64(0x44A014501414B428), SPH_C64(0x425BE1A3E1E1BADF),
	SPH_C64(0x4EB016581616A62C), SPH_C64(0xD2CD3AE83A3AF774),
	SPH_C64(0xD06F69B9696906D2), SPH_C64(0x2D48092409094112),
	SPH_C64(0xADA770DD7070D7E0), SPH_C64(0x54D9B6E2B6B66F71),
	SPH_C64(0xB7CED067D0D01EBD), SPH_C64(0x7E3BED93EDEDD6C7),
	SPH_C64(0xDB2ECC17CCCCE285), SPH_C64(0x572A421542426884),
	SPH_C64(0xC2B4985A98982C2D), SPH_C64(0x0E49A4AAA4A4ED55),
	SPH_C64(0x885D28A028287550), SPH_C64(0x31DA5C6D5C5C86B8),
	SPH_C64(0x3F93F8C7F8F86BED), SPH_C64(0xA44486228686C211)
};

__constant__ static const sph_u64 pT3[256] = {
	SPH_C64(0xC018601818D83078), SPH_C64(0x05238C23232646AF),
	SPH_C64(0x7EC63FC6C6B891F9), SPH_C64(0x13E887E8E8FBCD6F),
	SPH_C64(0x4C87268787CB13A1), SPH_C64(0xA9B8DAB8B8116D62),
	SPH_C64(0x0801040101090205), SPH_C64(0x424F214F4F0D9E6E),
	SPH_C64(0xAD36D836369B6CEE), SPH_C64(0x59A6A2A6A6FF5104),
	SPH_C64(0xDED26FD2D20CB9BD), SPH_C64(0xFBF5F3F5F50EF706),
	SPH_C64(0xEF79F9797996F280), SPH_C64(0x5F6FA16F6F30DECE),
	SPH_C64(0xFC917E91916D3FEF), SPH_C64(0xAA52555252F8A407),
	SPH_C64(0x27609D606047C0FD), SPH_C64(0x89BCCABCBC356576),
	SPH_C64(0xAC9B569B9B372BCD), SPH_C64(0x048E028E8E8A018C),
	SPH_C64(0x71A3B6A3A3D25B15), SPH_C64(0x600C300C0C6C183C),
	SPH_C64(0xFF7BF17B7B84F68A), SPH_C64(0xB535D43535806AE1),
	SPH_C64(0xE81D741D1DF53A69), SPH_C64(0x53E0A7E0E0B3DD47),
	SPH_C64(0xF6D77BD7D721B3AC), SPH_C64(0x5EC22FC2C29C99ED),
	SPH_C64(0x6D2EB82E2E435C96), SPH_C64(0x624B314B4B29967A),
	SPH_C64(0xA3FEDFFEFE5DE121), SPH_C64(0x8257415757D5AE16),
	SPH_C64(0xA815541515BD2A41), SPH_C64(0x9F77C17777E8EEB6),
	SPH_C64(0xA537DC3737926EEB), SPH_C64(0x7BE5B3E5E59ED756),
	SPH_C64(0x8C9F469F9F1323D9), SPH_C64(0xD3F0E7F0F023FD17),
	SPH_C64(0x6A4A354A4A20947F), SPH_C64(0x9EDA4FDADA44A995),
	SPH_C64(0xFA587D5858A2B025), SPH_C64(0x06C903C9C9CF8FCA),
	SPH_C64(0x5529A429297C528D), SPH_C64(0x500A280A0A5A1422),
	SPH_C64(0xE1B1FEB1B1507F4F), SPH_C64(0x69A0BAA0A0C95D1A),
	SPH_C64(0x7F6BB16B6B14D6DA), SPH_C64(0x5C852E8585D917AB),
	SPH_C64(0x81BDCEBDBD3C6773), SPH_C64(0xD25D695D5D8FBA34),
	SPH_C64(0x8010401010902050), SPH_C64(0xF3F4F7F4F407F503),
	SPH_C64(0x16CB0BCBCBDD8BC0), SPH_C64(0xED3EF83E3ED37CC6),
	SPH_C64(0x28051405052D0A11), SPH_C64(0x1F6781676778CEE6),
	SPH_C64(0x73E4B7E4E497D553), SPH_C64(0x25279C2727024EBB),
	SPH_C64(0x3241194141738258), SPH_C64(0x2C8B168B8BA70B9D),
	SPH_C64(0x51A7A6A7A7F65301), SPH_C64(0xCF7DE97D7DB2FA94),
	SPH_C64(0xDC956E95954937FB), SPH_C64(0x8ED847D8D856AD9F),
	SPH_C64(0x8BFBCBFBFB70EB30), SPH_C64(0x23EE9FEEEECDC171),
	SPH_C64(0xC77CED7C7CBBF891), SPH_C64(0x176685666671CCE3),
	SPH_C64(0xA6DD53DDDD7BA78E), SPH_C64(0xB8175C1717AF2E4B),
	SPH_C64(0x0247014747458E46), SPH_C64(0x849E429E9E1A21DC),
	SPH_C64(0x1ECA0FCACAD489C5), SPH_C64(0x752DB42D2D585A99),
	SPH_C64(0x91BFC6BFBF2E6379), SPH_C64(0x38071C07073F0E1B),
	SPH_C64(0x01AD8EADADAC4723), SPH_C64(0xEA5A755A5AB0B42F),
	SPH_C64(0x6C83368383EF1BB5), SPH_C64(0x8533CC3333B666FF),
	SPH_C64(0x3F639163635CC6F2), SPH_C64(0x100208020212040A),
	SPH_C64(0x39AA92AAAA934938), SPH_C64(0xAF71D97171DEE2A8),
	SPH_C64(0x0EC807C8C8C68DCF), SPH_C64(0xC819641919D1327D),
	SPH_C64(0x72493949493B9270), SPH_C64(0x86D943D9D95FAF9A),
	SPH_C64(0xC3F2EFF2F231F91D), SPH_C64(0x4BE3ABE3E3A8DB48),
	SPH_C64(0xE25B715B5BB9B62A), SPH_C64(0x34881A8888BC0D92),
	SPH_C64(0xA49A529A9A3E29C8), SPH_C64(0x2D269826260B4CBE),
	SPH_C64(0x8D32C83232BF64FA), SPH_C64(0xE9B0FAB0B0597D4A),
	SPH_C64(0x1BE983E9E9F2CF6A), SPH_C64(0x780F3C0F0F771E33),
	SPH_C64(0xE6D573D5D533B7A6), SPH_C64(0x74803A8080F41DBA),
	SPH_C64(0x99BEC2BEBE27617C), SPH_C64(0x26CD13CDCDEB87DE),
	SPH_C64(0xBD34D034348968E4), SPH_C64(0x7A483D4848329075),
	SPH_C64(0xABFFDBFFFF54E324), SPH_C64(0xF77AF57A7A8DF48F),
	SPH_C64(0xF4907A9090643DEA), SPH_C64(0xC25F615F5F9DBE3E),
	SPH_C64(0x1D208020203D40A0), SPH_C64(0x6768BD68680FD0D5),
	SPH_C64(0xD01A681A1ACA3472), SPH_C64(0x19AE82AEAEB7412C),
	SPH_C64(0xC9B4EAB4B47D755E), SPH_C64(0x9A544D5454CEA819),
	SPH_C64(0xEC937693937F3BE5), SPH_C64(0x0D228822222F44AA),
	SPH_C64(0x07648D646463C8E9), SPH_C64(0xDBF1E3F1F12AFF12),
	SPH_C64(0xBF73D17373CCE6A2), SPH_C64(0x901248121282245A),
	SPH_C64(0x3A401D40407A805D), SPH_C64(0x4008200808481028),
	SPH_C64(0x56C32BC3C3959BE8), SPH_C64(0x33EC97ECECDFC57B),
	SPH_C64(0x96DB4BDBDB4DAB90), SPH_C64(0x61A1BEA1A1C05F1F),
	SPH_C64(0x1C8D0E8D8D910783), SPH_C64(0xF53DF43D3DC87AC9),
	SPH_C64(0xCC976697975B33F1), SPH_C64(0x0000000000000000),
	SPH_C64(0x36CF1BCFCFF983D4), SPH_C64(0x452BAC2B2B6E5687),
	SPH_C64(0x9776C57676E1ECB3), SPH_C64(0x6482328282E619B0),
	SPH_C64(0xFED67FD6D628B1A9), SPH_C64(0xD81B6C1B1BC33677),
	SPH_C64(0xC1B5EEB5B574775B), SPH_C64(0x11AF86AFAFBE4329),
	SPH_C64(0x776AB56A6A1DD4DF), SPH_C64(0xBA505D5050EAA00D),
	SPH_C64(0x1245094545578A4C), SPH_C64(0xCBF3EBF3F338FB18),
	SPH_C64(0x9D30C03030AD60F0), SPH_C64(0x2BEF9BEFEFC4C374),
	SPH_C64(0xE53FFC3F3FDA7EC3), SPH_C64(0x9255495555C7AA1C),
	SPH_C64(0x79A2B2A2A2DB5910), SPH_C64(0x03EA8FEAEAE9C965),
	SPH_C64(0x0F658965656ACAEC), SPH_C64(0xB9BAD2BABA036968),
	SPH_C64(0x652FBC2F2F4A5E93), SPH_C64(0x4EC027C0C08E9DE7),
	SPH_C64(0xBEDE5FDEDE60A181), SPH_C64(0xE01C701C1CFC386C),
	SPH_C64(0xBBFDD3FDFD46E72E), SPH_C64(0x524D294D4D1F9A64),
	SPH_C64(0xE4927292927639E0), SPH_C64(0x8F75C97575FAEABC),
	SPH_C64(0x3006180606360C1E), SPH_C64(0x248A128A8AAE0998),
	SPH_C64(0xF9B2F2B2B24B7940), SPH_C64(0x63E6BFE6E685D159),
	SPH_C64(0x700E380E0E7E1C36), SPH_C64(0xF81F7C1F1FE73E63),
	SPH_C64(0x376295626255C4F7), SPH_C64(0xEED477D4D43AB5A3),
	SPH_C64(0x29A89AA8A8814D32), SPH_C64(0xC4966296965231F4),
	SPH_C64(0x9BF9C3F9F962EF3A), SPH_C64(0x66C533C5C5A397F6),
	SPH_C64(0x3525942525104AB1), SPH_C64(0xF259795959ABB220),
	SPH_C64(0x54842A8484D015AE), SPH_C64(0xB772D57272C5E4A7),
	SPH_C64(0xD539E43939EC72DD), SPH_C64(0x5A4C2D4C4C169861),
	SPH_C64(0xCA5E655E5E94BC3B), SPH_C64(0xE778FD78789FF085),
	SPH_C64(0xDD38E03838E570D8), SPH_C64(0x148C0A8C8C980586),
	SPH_C64(0xC6D163D1D117BFB2), SPH_C64(0x41A5AEA5A5E4570B),
	SPH_C64(0x43E2AFE2E2A1D94D), SPH_C64(0x2F619961614EC2F8),
	SPH_C64(0xF1B3F6B3B3427B45), SPH_C64(0x15218421213442A5),
	SPH_C64(0x949C4A9C9C0825D6), SPH_C64(0xF01E781E1EEE3C66),
	SPH_C64(0x2243114343618652), SPH_C64(0x76C73BC7C7B193FC),
	SPH_C64(0xB3FCD7FCFC4FE52B), SPH_C64(0x2004100404240814),
	SPH_C64(0xB251595151E3A208), SPH_C64(0xBC995E9999252FC7),
	SPH_C64(0x4F6DA96D6D22DAC4), SPH_C64(0x680D340D0D651A39),
	SPH_C64(0x83FACFFAFA79E935), SPH_C64(0xB6DF5BDFDF69A384),
	SPH_C64(0xD77EE57E7EA9FC9B), SPH_C64(0x3D249024241948B4),
	SPH_C64(0xC53BEC3B3BFE76D7), SPH_C64(0x31AB96ABAB9A4B3D),
	SPH_C64(0x3ECE1FCECEF081D1), SPH_C64(0x8811441111992255),
	SPH_C64(0x0C8F068F8F830389), SPH_C64(0x4A4E254E4E049C6B),
	SPH_C64(0xD1B7E6B7B7667351), SPH_C64(0x0BEB8BEBEBE0CB60),
	SPH_C64(0xFD3CF03C3CC178CC), SPH_C64(0x7C813E8181FD1FBF),
	SPH_C64(0xD4946A94944035FE), SPH_C64(0xEBF7FBF7F71CF30C),
	SPH_C64(0xA1B9DEB9B9186F67), SPH_C64(0x98134C13138B265F),
	SPH_C64(0x7D2CB02C2C51589C), SPH_C64(0xD6D36BD3D305BBB8),
	SPH_C64(0x6BE7BBE7E78CD35C), SPH_C64(0x576EA56E6E39DCCB),
	SPH_C64(0x6EC437C4C4AA95F3), SPH_C64(0x18030C03031B060F),
	SPH_C64(0x8A56455656DCAC13), SPH_C64(0x1A440D44445E8849),
	SPH_C64(0xDF7FE17F7FA0FE9E), SPH_C64(0x21A99EA9A9884F37),
	SPH_C64(0x4D2AA82A2A675482), SPH_C64(0xB1BBD6BBBB0A6B6D),
	SPH_C64(0x46C123C1C1879FE2), SPH_C64(0xA253515353F1A602),
	SPH_C64(0xAEDC57DCDC72A58B), SPH_C64(0x580B2C0B0B531627),
	SPH_C64(0x9C9D4E9D9D0127D3), SPH_C64(0x476CAD6C6C2BD8C1),
	SPH_C64(0x9531C43131A462F5), SPH_C64(0x8774CD7474F3E8B9),
	SPH_C64(0xE3F6FFF6F615F109), SPH_C64(0x0A460546464C8C43),
	SPH_C64(0x09AC8AACACA54526), SPH_C64(0x3C891E8989B50F97),
	SPH_C64(0xA014501414B42844), SPH_C64(0x5BE1A3E1E1BADF42),
	SPH_C64(0xB016581616A62C4E), SPH_C64(0xCD3AE83A3AF774D2),
	SPH_C64(0x6F69B9696906D2D0), SPH_C64(0x480924090941122D),
	SPH_C64(0xA770DD7070D7E0AD), SPH_C64(0xD9B6E2B6B66F7154),
	SPH_C64(0xCED067D0D01EBDB7), SPH_C64(0x3BED93EDEDD6C77E),
	SPH_C64(0x2ECC17CCCCE285DB), SPH_C64(0x2A42154242688457),
	SPH_C64(0xB4985A98982C2DC2), SPH_C64(0x49A4AAA4A4ED550E),
	SPH_C64(0x5D28A02828755088), SPH_C64(0xDA5C6D5C5C86B831),
	SPH_C64(0x93F8C7F8F86BED3F), SPH_C64(0x4486228686C211A4)
};

__constant__ static const sph_u64 pT4[256] = {
	SPH_C64(0x18601818D83078C0), SPH_C64(0x238C23232646AF05),
	SPH_C64(0xC63FC6C6B891F97E), SPH_C64(0xE887E8E8FBCD6F13),
	SPH_C64(0x87268787CB13A14C), SPH_C64(0xB8DAB8B8116D62A9),
	SPH_C64(0x0104010109020508), SPH_C64(0x4F214F4F0D9E6E42),
	SPH_C64(0x36D836369B6CEEAD), SPH_C64(0xA6A2A6A6FF510459),
	SPH_C64(0xD26FD2D20CB9BDDE), SPH_C64(0xF5F3F5F50EF706FB),
	SPH_C64(0x79F9797996F280EF), SPH_C64(0x6FA16F6F30DECE5F),
	SPH_C64(0x917E91916D3FEFFC), SPH_C64(0x52555252F8A407AA),
	SPH_C64(0x609D606047C0FD27), SPH_C64(0xBCCABCBC35657689),
	SPH_C64(0x9B569B9B372BCDAC), SPH_C64(0x8E028E8E8A018C04),
	SPH_C64(0xA3B6A3A3D25B1571), SPH_C64(0x0C300C0C6C183C60),
	SPH_C64(0x7BF17B7B84F68AFF), SPH_C64(0x35D43535806AE1B5),
	SPH_C64(0x1D741D1DF53A69E8), SPH_C64(0xE0A7E0E0B3DD4753),
	SPH_C64(0xD77BD7D721B3ACF6), SPH_C64(0xC22FC2C29C99ED5E),
	SPH_C64(0x2EB82E2E435C966D), SPH_C64(0x4B314B4B29967A62),
	SPH_C64(0xFEDFFEFE5DE121A3), SPH_C64(0x57415757D5AE1682),
	SPH_C64(0x15541515BD2A41A8), SPH_C64(0x77C17777E8EEB69F),
	SPH_C64(0x37DC3737926EEBA5), SPH_C64(0xE5B3E5E59ED7567B),
	SPH_C64(0x9F469F9F1323D98C), SPH_C64(0xF0E7F0F023FD17D3),
	SPH_C64(0x4A354A4A20947F6A), SPH_C64(0xDA4FDADA44A9959E),
	SPH_C64(0x587D5858A2B025FA), SPH_C64(0xC903C9C9CF8FCA06),
	SPH_C64(0x29A429297C528D55), SPH_C64(0x0A280A0A5A142250),
	SPH_C64(0xB1FEB1B1507F4FE1), SPH_C64(0xA0BAA0A0C95D1A69),
	SPH_C64(0x6BB16B6B14D6DA7F), SPH_C64(0x852E8585D917AB5C),
	SPH_C64(0xBDCEBDBD3C677381), SPH_C64(0x5D695D5D8FBA34D2),
	SPH_C64(0x1040101090205080), SPH_C64(0xF4F7F4F407F503F3),
	SPH_C64(0xCB0BCBCBDD8BC016), SPH_C64(0x3EF83E3ED37CC6ED),
	SPH_C64(0x051405052D0A1128), SPH_C64(0x6781676778CEE61F),
	SPH_C64(0xE4B7E4E497D55373), SPH_C64(0x279C2727024EBB25),
	SPH_C64(0x4119414173825832), SPH_C64(0x8B168B8BA70B9D2C),
	SPH_C64(0xA7A6A7A7F6530151), SPH_C64(0x7DE97D7DB2FA94CF),
	SPH_C64(0x956E95954937FBDC), SPH_C64(0xD847D8D856AD9F8E),
	SPH_C64(0xFBCBFBFB70EB308B), SPH_C64(0xEE9FEEEECDC17123),
	SPH_C64(0x7CED7C7CBBF891C7), SPH_C64(0x6685666671CCE317),
	SPH_C64(0xDD53DDDD7BA78EA6), SPH_C64(0x175C1717AF2E4BB8),
	SPH_C64(0x47014747458E4602), SPH_C64(0x9E429E9E1A21DC84),
	SPH_C64(0xCA0FCACAD489C51E), SPH_C64(0x2DB42D2D585A9975),
	SPH_C64(0xBFC6BFBF2E637991), SPH_C64(0x071C07073F0E1B38),
	SPH_C64(0xAD8EADADAC472301), SPH_C64(0x5A755A5AB0B42FEA),
	SPH_C64(0x83368383EF1BB56C), SPH_C64(0x33CC3333B666FF85),
	SPH_C64(0x639163635CC6F23F), SPH_C64(0x0208020212040A10),
	SPH_C64(0xAA92AAAA93493839), SPH_C64(0x71D97171DEE2A8AF),
	SPH_C64(0xC807C8C8C68DCF0E), SPH_C64(0x19641919D1327DC8),
	SPH_C64(0x493949493B927072), SPH_C64(0xD943D9D95FAF9A86),
	SPH_C64(0xF2EFF2F231F91DC3), SPH_C64(0xE3ABE3E3A8DB484B),
	SPH_C64(0x5B715B5BB9B62AE2), SPH_C64(0x881A8888BC0D9234),
	SPH_C64(0x9A529A9A3E29C8A4), SPH_C64(0x269826260B4CBE2D),
	SPH_C64(0x32C83232BF64FA8D), SPH_C64(0xB0FAB0B0597D4AE9),
	SPH_C64(0xE983E9E9F2CF6A1B), SPH_C64(0x0F3C0F0F771E3378),
	SPH_C64(0xD573D5D533B7A6E6), SPH_C64(0x803A8080F41DBA74),
	SPH_C64(0xBEC2BEBE27617C99), SPH_C64(0xCD13CDCDEB87DE26),
	SPH_C64(0x34D034348968E4BD), SPH_C64(0x483D48483290757A),
	SPH_C64(0xFFDBFFFF54E324AB), SPH_C64(0x7AF57A7A8DF48FF7),
	SPH_C64(0x907A9090643DEAF4), SPH_C64(0x5F615F5F9DBE3EC2),
	SPH_C64(0x208020203D40A01D), SPH_C64(0x68BD68680FD0D567),
	SPH_C64(0x1A681A1ACA3472D0), SPH_C64(0xAE82AEAEB7412C19),
	SPH_C64(0xB4EAB4B47D755EC9), SPH_C64(0x544D5454CEA8199A),
	SPH_C64(0x937693937F3BE5EC), SPH_C64(0x228822222F44AA0D),
	SPH_C64(0x648D646463C8E907), SPH_C64(0xF1E3F1F12AFF12DB),
	SPH_C64(0x73D17373CCE6A2BF), SPH_C64(0x1248121282245A90),
	SPH_C64(0x401D40407A805D3A), SPH_C64(0x0820080848102840),
	SPH_C64(0xC32BC3C3959BE856), SPH_C64(0xEC97ECECDFC57B33),
	SPH_C64(0xDB4BDBDB4DAB9096), SPH_C64(0xA1BEA1A1C05F1F61),
	SPH_C64(0x8D0E8D8D9107831C), SPH_C64(0x3DF43D3DC87AC9F5),
	SPH_C64(0x976697975B33F1CC), SPH_C64(0x0000000000000000),
	SPH_C64(0xCF1BCFCFF983D436), SPH_C64(0x2BAC2B2B6E568745),
	SPH_C64(0x76C57676E1ECB397), SPH_C64(0x82328282E619B064),
	SPH_C64(0xD67FD6D628B1A9FE), SPH_C64(0x1B6C1B1BC33677D8),
	SPH_C64(0xB5EEB5B574775BC1), SPH_C64(0xAF86AFAFBE432911),
	SPH_C64(0x6AB56A6A1DD4DF77), SPH_C64(0x505D5050EAA00DBA),
	SPH_C64(0x45094545578A4C12), SPH_C64(0xF3EBF3F338FB18CB),
	SPH_C64(0x30C03030AD60F09D), SPH_C64(0xEF9BEFEFC4C3742B),
	SPH_C64(0x3FFC3F3FDA7EC3E5), SPH_C64(0x55495555C7AA1C92),
	SPH_C64(0xA2B2A2A2DB591079), SPH_C64(0xEA8FEAEAE9C96503),
	SPH_C64(0x658965656ACAEC0F), SPH_C64(0xBAD2BABA036968B9),
	SPH_C64(0x2FBC2F2F4A5E9365), SPH_C64(0xC027C0C08E9DE74E),
	SPH_C64(0xDE5FDEDE60A181BE), SPH_C64(0x1C701C1CFC386CE0),
	SPH_C64(0xFDD3FDFD46E72EBB), SPH_C64(0x4D294D4D1F9A6452),
	SPH_C64(0x927292927639E0E4), SPH_C64(0x75C97575FAEABC8F),
	SPH_C64(0x06180606360C1E30), SPH_C64(0x8A128A8AAE099824),
	SPH_C64(0xB2F2B2B24B7940F9), SPH_C64(0xE6BFE6E685D15963),
	SPH_C64(0x0E380E0E7E1C3670), SPH_C64(0x1F7C1F1FE73E63F8),
	SPH_C64(0x6295626255C4F737), SPH_C64(0xD477D4D43AB5A3EE),
	SPH_C64(0xA89AA8A8814D3229), SPH_C64(0x966296965231F4C4),
	SPH_C64(0xF9C3F9F962EF3A9B), SPH_C64(0xC533C5C5A397F666),
	SPH_C64(0x25942525104AB135), SPH_C64(0x59795959ABB220F2),
	SPH_C64(0x842A8484D015AE54), SPH_C64(0x72D57272C5E4A7B7),
	SPH_C64(0x39E43939EC72DDD5), SPH_C64(0x4C2D4C4C1698615A),
	SPH_C64(0x5E655E5E94BC3BCA), SPH_C64(0x78FD78789FF085E7),
	SPH_C64(0x38E03838E570D8DD), SPH_C64(0x8C0A8C8C98058614),
	SPH_C64(0xD163D1D117BFB2C6), SPH_C64(0xA5AEA5A5E4570B41),
	SPH_C64(0xE2AFE2E2A1D94D43), SPH_C64(0x619961614EC2F82F),
	SPH_C64(0xB3F6B3B3427B45F1), SPH_C64(0x218421213442A515),
	SPH_C64(0x9C4A9C9C0825D694), SPH_C64(0x1E781E1EEE3C66F0),
	SPH_C64(0x4311434361865222), SPH_C64(0xC73BC7C7B193FC76),
	SPH_C64(0xFCD7FCFC4FE52BB3), SPH_C64(0x0410040424081420),
	SPH_C64(0x51595151E3A208B2), SPH_C64(0x995E9999252FC7BC),
	SPH_C64(0x6DA96D6D22DAC44F), SPH_C64(0x0D340D0D651A3968),
	SPH_C64(0xFACFFAFA79E93583), SPH_C64(0xDF5BDFDF69A384B6),
	SPH_C64(0x7EE57E7EA9FC9BD7), SPH_C64(0x249024241948B43D),
	SPH_C64(0x3BEC3B3BFE76D7C5), SPH_C64(0xAB96ABAB9A4B3D31),
	SPH_C64(0xCE1FCECEF081D13E), SPH_C64(0x1144111199225588),
	SPH_C64(0x8F068F8F8303890C), SPH_C64(0x4E254E4E049C6B4A),
	SPH_C64(0xB7E6B7B7667351D1), SPH_C64(0xEB8BEBEBE0CB600B),
	SPH_C64(0x3CF03C3CC178CCFD), SPH_C64(0x813E8181FD1FBF7C),
	SPH_C64(0x946A94944035FED4), SPH_C64(0xF7FBF7F71CF30CEB),
	SPH_C64(0xB9DEB9B9186F67A1), SPH_C64(0x134C13138B265F98),
	SPH_C64(0x2CB02C2C51589C7D), SPH_C64(0xD36BD3D305BBB8D6),
	SPH_C64(0xE7BBE7E78CD35C6B), SPH_C64(0x6EA56E6E39DCCB57),
	SPH_C64(0xC437C4C4AA95F36E), SPH_C64(0x030C03031B060F18),
	SPH_C64(0x56455656DCAC138A), SPH_C64(0x440D44445E88491A),
	SPH_C64(0x7FE17F7FA0FE9EDF), SPH_C64(0xA99EA9A9884F3721),
	SPH_C64(0x2AA82A2A6754824D), SPH_C64(0xBBD6BBBB0A6B6DB1),
	SPH_C64(0xC123C1C1879FE246), SPH_C64(0x53515353F1A602A2),
	SPH_C64(0xDC57DCDC72A58BAE), SPH_C64(0x0B2C0B0B53162758),
	SPH_C64(0x9D4E9D9D0127D39C), SPH_C64(0x6CAD6C6C2BD8C147),
	SPH_C64(0x31C43131A462F595), SPH_C64(0x74CD7474F3E8B987),
	SPH_C64(0xF6FFF6F615F109E3), SPH_C64(0x460546464C8C430A),
	SPH_C64(0xAC8AACACA5452609), SPH_C64(0x891E8989B50F973C),
	SPH_C64(0x14501414B42844A0), SPH_C64(0xE1A3E1E1BADF425B),
	SPH_C64(0x16581616A62C4EB0), SPH_C64(0x3AE83A3AF774D2CD),
	SPH_C64(0x69B9696906D2D06F), SPH_C64(0x0924090941122D48),
	SPH_C64(0x70DD7070D7E0ADA7), SPH_C64(0xB6E2B6B66F7154D9),
	SPH_C64(0xD067D0D01EBDB7CE), SPH_C64(0xED93EDEDD6C77E3B),
	SPH_C64(0xCC17CCCCE285DB2E), SPH_C64(0x421542426884572A),
	SPH_C64(0x985A98982C2DC2B4), SPH_C64(0xA4AAA4A4ED550E49),
	SPH_C64(0x28A028287550885D), SPH_C64(0x5C6D5C5C86B831DA),
	SPH_C64(0xF8C7F8F86BED3F93), SPH_C64(0x86228686C211A444)
};

__constant__ static const sph_u64 pT5[256] = {
	SPH_C64(0x601818D83078C018), SPH_C64(0x8C23232646AF0523),
	SPH_C64(0x3FC6C6B891F97EC6), SPH_C64(0x87E8E8FBCD6F13E8),
	SPH_C64(0x268787CB13A14C87), SPH_C64(0xDAB8B8116D62A9B8),
	SPH_C64(0x0401010902050801), SPH_C64(0x214F4F0D9E6E424F),
	SPH_C64(0xD836369B6CEEAD36), SPH_C64(0xA2A6A6FF510459A6),
	SPH_C64(0x6FD2D20CB9BDDED2), SPH_C64(0xF3F5F50EF706FBF5),
	SPH_C64(0xF9797996F280EF79), SPH_C64(0xA16F6F30DECE5F6F),
	SPH_C64(0x7E91916D3FEFFC91), SPH_C64(0x555252F8A407AA52),
	SPH_C64(0x9D606047C0FD2760), SPH_C64(0xCABCBC35657689BC),
	SPH_C64(0x569B9B372BCDAC9B), SPH_C64(0x028E8E8A018C048E),
	SPH_C64(0xB6A3A3D25B1571A3), SPH_C64(0x300C0C6C183C600C),
	SPH_C64(0xF17B7B84F68AFF7B), SPH_C64(0xD43535806AE1B535),
	SPH_C64(0x741D1DF53A69E81D), SPH_C64(0xA7E0E0B3DD4753E0),
	SPH_C64(0x7BD7D721B3ACF6D7), SPH_C64(0x2FC2C29C99ED5EC2),
	SPH_C64(0xB82E2E435C966D2E), SPH_C64(0x314B4B29967A624B),
	SPH_C64(0xDFFEFE5DE121A3FE), SPH_C64(0x415757D5AE168257),
	SPH_C64(0x541515BD2A41A815), SPH_C64(0xC17777E8EEB69F77),
	SPH_C64(0xDC3737926EEBA537), SPH_C64(0xB3E5E59ED7567BE5),
	SPH_C64(0x469F9F1323D98C9F), SPH_C64(0xE7F0F023FD17D3F0),
	SPH_C64(0x354A4A20947F6A4A), SPH_C64(0x4FDADA44A9959EDA),
	SPH_C64(0x7D5858A2B025FA58), SPH_C64(0x03C9C9CF8FCA06C9),
	SPH_C64(0xA429297C528D5529), SPH_C64(0x280A0A5A1422500A),
	SPH_C64(0xFEB1B1507F4FE1B1), SPH_C64(0xBAA0A0C95D1A69A0),
	SPH_C64(0xB16B6B14D6DA7F6B), SPH_C64(0x2E8585D917AB5C85),
	SPH_C64(0xCEBDBD3C677381BD), SPH_C64(0x695D5D8FBA34D25D),
	SPH_C64(0x4010109020508010), SPH_C64(0xF7F4F407F503F3F4),
	SPH_C64(0x0BCBCBDD8BC016CB), SPH_C64(0xF83E3ED37CC6ED3E),
	SPH_C64(0x1405052D0A112805), SPH_C64(0x81676778CEE61F67),
	SPH_C64(0xB7E4E497D55373E4), SPH_C64(0x9C2727024EBB2527),
	SPH_C64(0x1941417382583241), SPH_C64(0x168B8BA70B9D2C8B),
	SPH_C64(0xA6A7A7F6530151A7), SPH_C64(0xE97D7DB2FA94CF7D),
	SPH_C64(0x6E95954937FBDC95), SPH_C64(0x47D8D856AD9F8ED8),
	SPH_C64(0xCBFBFB70EB308BFB), SPH_C64(0x9FEEEECDC17123EE),
	SPH_C64(0xED7C7CBBF891C77C), SPH_C64(0x85666671CCE31766),
	SPH_C64(0x53DDDD7BA78EA6DD), SPH_C64(0x5C1717AF2E4BB817),
	SPH_C64(0x014747458E460247), SPH_C64(0x429E9E1A21DC849E),
	SPH_C64(0x0FCACAD489C51ECA), SPH_C64(0xB42D2D585A99752D),
	SPH_C64(0xC6BFBF2E637991BF), SPH_C64(0x1C07073F0E1B3807),
	SPH_C64(0x8EADADAC472301AD), SPH_C64(0x755A5AB0B42FEA5A),
	SPH_C64(0x368383EF1BB56C83), SPH_C64(0xCC3333B666FF8533),
	SPH_C64(0x9163635CC6F23F63), SPH_C64(0x08020212040A1002),
	SPH_C64(0x92AAAA93493839AA), SPH_C64(0xD97171DEE2A8AF71),
	SPH_C64(0x07C8C8C68DCF0EC8), SPH_C64(0x641919D1327DC819),
	SPH_C64(0x3949493B92707249), SPH_C64(0x43D9D95FAF9A86D9),
	SPH_C64(0xEFF2F231F91DC3F2), SPH_C64(0xABE3E3A8DB484BE3),
	SPH_C64(0x715B5BB9B62AE25B), SPH_C64(0x1A8888BC0D923488),
	SPH_C64(0x529A9A3E29C8A49A), SPH_C64(0x9826260B4CBE2D26),
	SPH_C64(0xC83232BF64FA8D32), SPH_C64(0xFAB0B0597D4AE9B0),
	SPH_C64(0x83E9E9F2CF6A1BE9), SPH_C64(0x3C0F0F771E33780F),
	SPH_C64(0x73D5D533B7A6E6D5), SPH_C64(0x3A8080F41DBA7480),
	SPH_C64(0xC2BEBE27617C99BE), SPH_C64(0x13CDCDEB87DE26CD),
	SPH_C64(0xD034348968E4BD34), SPH_C64(0x3D48483290757A48),
	SPH_C64(0xDBFFFF54E324ABFF), SPH_C64(0xF57A7A8DF48FF77A),
	SPH_C64(0x7A9090643DEAF490), SPH_C64(0x615F5F9DBE3EC25F),
	SPH_C64(0x8020203D40A01D20), SPH_C64(0xBD68680FD0D56768),
	SPH_C64(0x681A1ACA3472D01A), SPH_C64(0x82AEAEB7412C19AE),
	SPH_C64(0xEAB4B47D755EC9B4), SPH_C64(0x4D5454CEA8199A54),
	SPH_C64(0x7693937F3BE5EC93), SPH_C64(0x8822222F44AA0D22),
	SPH_C64(0x8D646463C8E90764), SPH_C64(0xE3F1F12AFF12DBF1),
	SPH_C64(0xD17373CCE6A2BF73), SPH_C64(0x48121282245A9012),
	SPH_C64(0x1D40407A805D3A40), SPH_C64(0x2008084810284008),
	SPH_C64(0x2BC3C3959BE856C3), SPH_C64(0x97ECECDFC57B33EC),
	SPH_C64(0x4BDBDB4DAB9096DB), SPH_C64(0xBEA1A1C05F1F61A1),
	SPH_C64(0x0E8D8D9107831C8D), SPH_C64(0xF43D3DC87AC9F53D),
	SPH_C64(0x6697975B33F1CC97), SPH_C64(0x0000000000000000),
	SPH_C64(0x1BCFCFF983D436CF), SPH_C64(0xAC2B2B6E5687452B),
	SPH_C64(0xC57676E1ECB39776), SPH_C64(0x328282E619B06482),
	SPH_C64(0x7FD6D628B1A9FED6), SPH_C64(0x6C1B1BC33677D81B),
	SPH_C64(0xEEB5B574775BC1B5), SPH_C64(0x86AFAFBE432911AF),
	SPH_C64(0xB56A6A1DD4DF776A), SPH_C64(0x5D5050EAA00DBA50),
	SPH_C64(0x094545578A4C1245), SPH_C64(0xEBF3F338FB18CBF3),
	SPH_C64(0xC03030AD60F09D30), SPH_C64(0x9BEFEFC4C3742BEF),
	SPH_C64(0xFC3F3FDA7EC3E53F), SPH_C64(0x495555C7AA1C9255),
	SPH_C64(0xB2A2A2DB591079A2), SPH_C64(0x8FEAEAE9C96503EA),
	SPH_C64(0x8965656ACAEC0F65), SPH_C64(0xD2BABA036968B9BA),
	SPH_C64(0xBC2F2F4A5E93652F), SPH_C64(0x27C0C08E9DE74EC0),
	SPH_C64(0x5FDEDE60A181BEDE), SPH_C64(0x701C1CFC386CE01C),
	SPH_C64(0xD3FDFD46E72EBBFD), SPH_C64(0x294D4D1F9A64524D),
	SPH_C64(0x7292927639E0E492), SPH_C64(0xC97575FAEABC8F75),
	SPH_C64(0x180606360C1E3006), SPH_C64(0x128A8AAE0998248A),
	SPH_C64(0xF2B2B24B7940F9B2), SPH_C64(0xBFE6E685D15963E6),
	SPH_C64(0x380E0E7E1C36700E), SPH_C64(0x7C1F1FE73E63F81F),
	SPH_C64(0x95626255C4F73762), SPH_C64(0x77D4D43AB5A3EED4),
	SPH_C64(0x9AA8A8814D3229A8), SPH_C64(0x6296965231F4C496),
	SPH_C64(0xC3F9F962EF3A9BF9), SPH_C64(0x33C5C5A397F666C5),
	SPH_C64(0x942525104AB13525), SPH_C64(0x795959ABB220F259),
	SPH_C64(0x2A8484D015AE5484), SPH_C64(0xD57272C5E4A7B772),
	SPH_C64(0xE43939EC72DDD539), SPH_C64(0x2D4C4C1698615A4C),
	SPH_C64(0x655E5E94BC3BCA5E), SPH_C64(0xFD78789FF085E778),
	SPH_C64(0xE03838E570D8DD38), SPH_C64(0x0A8C8C980586148C),
	SPH_C64(0x63D1D117BFB2C6D1), SPH_C64(0xAEA5A5E4570B41A5),
	SPH_C64(0xAFE2E2A1D94D43E2), SPH_C64(0x9961614EC2F82F61),
	SPH_C64(0xF6B3B3427B45F1B3), SPH_C64(0x8421213442A51521),
	SPH_C64(0x4A9C9C0825D6949C), SPH_C64(0x781E1EEE3C66F01E),
	SPH_C64(0x1143436186522243), SPH_C64(0x3BC7C7B193FC76C7),
	SPH_C64(0xD7FCFC4FE52BB3FC), SPH_C64(0x1004042408142004),
	SPH_C64(0x595151E3A208B251), SPH_C64(0x5E9999252FC7BC99),
	SPH_C64(0xA96D6D22DAC44F6D), SPH_C64(0x340D0D651A39680D),
	SPH_C64(0xCFFAFA79E93583FA), SPH_C64(0x5BDFDF69A384B6DF),
	SPH_C64(0xE57E7EA9FC9BD77E), SPH_C64(0x9024241948B43D24),
	SPH_C64(0xEC3B3BFE76D7C53B), SPH_C64(0x96ABAB9A4B3D31AB),
	SPH_C64(0x1FCECEF081D13ECE), SPH_C64(0x4411119922558811),
	SPH_C64(0x068F8F8303890C8F), SPH_C64(0x254E4E049C6B4A4E),
	SPH_C64(0xE6B7B7667351D1B7), SPH_C64(0x8BEBEBE0CB600BEB),
	SPH_C64(0xF03C3CC178CCFD3C), SPH_C64(0x3E8181FD1FBF7C81),
	SPH_C64(0x6A94944035FED494), SPH_C64(0xFBF7F71CF30CEBF7),
	SPH_C64(0xDEB9B9186F67A1B9), SPH_C64(0x4C13138B265F9813),
	SPH_C64(0xB02C2C51589C7D2C), SPH_C64(0x6BD3D305BBB8D6D3),
	SPH_C64(0xBBE7E78CD35C6BE7), SPH_C64(0xA56E6E39DCCB576E),
	SPH_C64(0x37C4C4AA95F36EC4), SPH_C64(0x0C03031B060F1803),
	SPH_C64(0x455656DCAC138A56), SPH_C64(0x0D44445E88491A44),
	SPH_C64(0xE17F7FA0FE9EDF7F), SPH_C64(0x9EA9A9884F3721A9),
	SPH_C64(0xA82A2A6754824D2A), SPH_C64(0xD6BBBB0A6B6DB1BB),
	SPH_C64(0x23C1C1879FE246C1), SPH_C64(0x515353F1A602A253),
	SPH_C64(0x57DCDC72A58BAEDC), SPH_C64(0x2C0B0B531627580B),
	SPH_C64(0x4E9D9D0127D39C9D), SPH_C64(0xAD6C6C2BD8C1476C),
	SPH_C64(0xC43131A462F59531), SPH_C64(0xCD7474F3E8B98774),
	SPH_C64(0xFFF6F615F109E3F6), SPH_C64(0x0546464C8C430A46),
	SPH_C64(0x8AACACA5452609AC), SPH_C64(0x1E8989B50F973C89),
	SPH_C64(0x501414B42844A014), SPH_C64(0xA3E1E1BADF425BE1),
	SPH_C64(0x581616A62C4EB016), SPH_C64(0xE83A3AF774D2CD3A),
	SPH_C64(0xB9696906D2D06F69), SPH_C64(0x24090941122D4809),
	SPH_C64(0xDD7070D7E0ADA770), SPH_C64(0xE2B6B66F7154D9B6),
	SPH_C64(0x67D0D01EBDB7CED0), SPH_C64(0x93EDEDD6C77E3BED),
	SPH_C64(0x17CCCCE285DB2ECC), SPH_C64(0x1542426884572A42),
	SPH_C64(0x5A98982C2DC2B498), SPH_C64(0xAAA4A4ED550E49A4),
	SPH_C64(0xA028287550885D28), SPH_C64(0x6D5C5C86B831DA5C),
	SPH_C64(0xC7F8F86BED3F93F8), SPH_C64(0x228686C211A44486)
};

__constant__ static const sph_u64 pT6[256] = {
	SPH_C64(0x1818D83078C01860), SPH_C64(0x23232646AF05238C),
	SPH_C64(0xC6C6B891F97EC63F), SPH_C64(0xE8E8FBCD6F13E887),
	SPH_C64(0x8787CB13A14C8726), SPH_C64(0xB8B8116D62A9B8DA),
	SPH_C64(0x0101090205080104), SPH_C64(0x4F4F0D9E6E424F21),
	SPH_C64(0x36369B6CEEAD36D8), SPH_C64(0xA6A6FF510459A6A2),
	SPH_C64(0xD2D20CB9BDDED26F), SPH_C64(0xF5F50EF706FBF5F3),
	SPH_C64(0x797996F280EF79F9), SPH_C64(0x6F6F30DECE5F6FA1),
	SPH_C64(0x91916D3FEFFC917E), SPH_C64(0x5252F8A407AA5255),
	SPH_C64(0x606047C0FD27609D), SPH_C64(0xBCBC35657689BCCA),
	SPH_C64(0x9B9B372BCDAC9B56), SPH_C64(0x8E8E8A018C048E02),
	SPH_C64(0xA3A3D25B1571A3B6), SPH_C64(0x0C0C6C183C600C30),
	SPH_C64(0x7B7B84F68AFF7BF1), SPH_C64(0x3535806AE1B535D4),
	SPH_C64(0x1D1DF53A69E81D74), SPH_C64(0xE0E0B3DD4753E0A7),
	SPH_C64(0xD7D721B3ACF6D77B), SPH_C64(0xC2C29C99ED5EC22F),
	SPH_C64(0x2E2E435C966D2EB8), SPH_C64(0x4B4B29967A624B31),
	SPH_C64(0xFEFE5DE121A3FEDF), SPH_C64(0x5757D5AE16825741),
	SPH_C64(0x1515BD2A41A81554), SPH_C64(0x7777E8EEB69F77C1),
	SPH_C64(0x3737926EEBA537DC), SPH_C64(0xE5E59ED7567BE5B3),
	SPH_C64(0x9F9F1323D98C9F46), SPH_C64(0xF0F023FD17D3F0E7),
	SPH_C64(0x4A4A20947F6A4A35), SPH_C64(0xDADA44A9959EDA4F),
	SPH_C64(0x5858A2B025FA587D), SPH_C64(0xC9C9CF8FCA06C903),
	SPH_C64(0x29297C528D5529A4), SPH_C64(0x0A0A5A1422500A28),
	SPH_C64(0xB1B1507F4FE1B1FE), SPH_C64(0xA0A0C95D1A69A0BA),
	SPH_C64(0x6B6B14D6DA7F6BB1), SPH_C64(0x8585D917AB5C852E),
	SPH_C64(0xBDBD3C677381BDCE), SPH_C64(0x5D5D8FBA34D25D69),
	SPH_C64(0x1010902050801040), SPH_C64(0xF4F407F503F3F4F7),
	SPH_C64(0xCBCBDD8BC016CB0B), SPH_C64(0x3E3ED37CC6ED3EF8),
	SPH_C64(0x05052D0A11280514), SPH_C64(0x676778CEE61F6781),
	SPH_C64(0xE4E497D55373E4B7), SPH_C64(0x2727024EBB25279C),
	SPH_C64(0x4141738258324119), SPH_C64(0x8B8BA70B9D2C8B16),
	SPH_C64(0xA7A7F6530151A7A6), SPH_C64(0x7D7DB2FA94CF7DE9),
	SPH_C64(0x95954937FBDC956E), SPH_C64(0xD8D856AD9F8ED847),
	SPH_C64(0xFBFB70EB308BFBCB), SPH_C64(0xEEEECDC17123EE9F),
	SPH_C64(0x7C7CBBF891C77CED), SPH_C64(0x666671CCE3176685),
	SPH_C64(0xDDDD7BA78EA6DD53), SPH_C64(0x1717AF2E4BB8175C),
	SPH_C64(0x4747458E46024701), SPH_C64(0x9E9E1A21DC849E42),
	SPH_C64(0xCACAD489C51ECA0F), SPH_C64(0x2D2D585A99752DB4),
	SPH_C64(0xBFBF2E637991BFC6), SPH_C64(0x07073F0E1B38071C),
	SPH_C64(0xADADAC472301AD8E), SPH_C64(0x5A5AB0B42FEA5A75),
	SPH_C64(0x8383EF1BB56C8336), SPH_C64(0x3333B666FF8533CC),
	SPH_C64(0x63635CC6F23F6391), SPH_C64(0x020212040A100208),
	SPH_C64(0xAAAA93493839AA92), SPH_C64(0x7171DEE2A8AF71D9),
	SPH_C64(0xC8C8C68DCF0EC807), SPH_C64(0x1919D1327DC81964),
	SPH_C64(0x49493B9270724939), SPH_C64(0xD9D95FAF9A86D943),
	SPH_C64(0xF2F231F91DC3F2EF), SPH_C64(0xE3E3A8DB484BE3AB),
	SPH_C64(0x5B5BB9B62AE25B71), SPH_C64(0x8888BC0D9234881A),
	SPH_C64(0x9A9A3E29C8A49A52), SPH_C64(0x26260B4CBE2D2698),
	SPH_C64(0x3232BF64FA8D32C8), SPH_C64(0xB0B0597D4AE9B0FA),
	SPH_C64(0xE9E9F2CF6A1BE983), SPH_C64(0x0F0F771E33780F3C),
	SPH_C64(0xD5D533B7A6E6D573), SPH_C64(0x8080F41DBA74803A),
	SPH_C64(0xBEBE27617C99BEC2), SPH_C64(0xCDCDEB87DE26CD13),
	SPH_C64(0x34348968E4BD34D0), SPH_C64(0x48483290757A483D),
	SPH_C64(0xFFFF54E324ABFFDB), SPH_C64(0x7A7A8DF48FF77AF5),
	SPH_C64(0x9090643DEAF4907A), SPH_C64(0x5F5F9DBE3EC25F61),
	SPH_C64(0x20203D40A01D2080), SPH_C64(0x68680FD0D56768BD),
	SPH_C64(0x1A1ACA3472D01A68), SPH_C64(0xAEAEB7412C19AE82),
	SPH_C64(0xB4B47D755EC9B4EA), SPH_C64(0x5454CEA8199A544D),
	SPH_C64(0x93937F3BE5EC9376), SPH_C64(0x22222F44AA0D2288),
	SPH_C64(0x646463C8E907648D), SPH_C64(0xF1F12AFF12DBF1E3),
	SPH_C64(0x7373CCE6A2BF73D1), SPH_C64(0x121282245A901248),
	SPH_C64(0x40407A805D3A401D), SPH_C64(0x0808481028400820),
	SPH_C64(0xC3C3959BE856C32B), SPH_C64(0xECECDFC57B33EC97),
	SPH_C64(0xDBDB4DAB9096DB4B), SPH_C64(0xA1A1C05F1F61A1BE),
	SPH_C64(0x8D8D9107831C8D0E), SPH_C64(0x3D3DC87AC9F53DF4),
	SPH_C64(0x97975B33F1CC9766), SPH_C64(0x0000000000000000),
	SPH_C64(0xCFCFF983D436CF1B), SPH_C64(0x2B2B6E5687452BAC),
	SPH_C64(0x7676E1ECB39776C5), SPH_C64(0x8282E619B0648232),
	SPH_C64(0xD6D628B1A9FED67F), SPH_C64(0x1B1BC33677D81B6C),
	SPH_C64(0xB5B574775BC1B5EE), SPH_C64(0xAFAFBE432911AF86),
	SPH_C64(0x6A6A1DD4DF776AB5), SPH_C64(0x5050EAA00DBA505D),
	SPH_C64(0x4545578A4C124509), SPH_C64(0xF3F338FB18CBF3EB),
	SPH_C64(0x3030AD60F09D30C0), SPH_C64(0xEFEFC4C3742BEF9B),
	SPH_C64(0x3F3FDA7EC3E53FFC), SPH_C64(0x5555C7AA1C925549),
	SPH_C64(0xA2A2DB591079A2B2), SPH_C64(0xEAEAE9C96503EA8F),
	SPH_C64(0x65656ACAEC0F6589), SPH_C64(0xBABA036968B9BAD2),
	SPH_C64(0x2F2F4A5E93652FBC), SPH_C64(0xC0C08E9DE74EC027),
	SPH_C64(0xDEDE60A181BEDE5F), SPH_C64(0x1C1CFC386CE01C70),
	SPH_C64(0xFDFD46E72EBBFDD3), SPH_C64(0x4D4D1F9A64524D29),
	SPH_C64(0x92927639E0E49272), SPH_C64(0x7575FAEABC8F75C9),
	SPH_C64(0x0606360C1E300618), SPH_C64(0x8A8AAE0998248A12),
	SPH_C64(0xB2B24B7940F9B2F2), SPH_C64(0xE6E685D15963E6BF),
	SPH_C64(0x0E0E7E1C36700E38), SPH_C64(0x1F1FE73E63F81F7C),
	SPH_C64(0x626255C4F7376295), SPH_C64(0xD4D43AB5A3EED477),
	SPH_C64(0xA8A8814D3229A89A), SPH_C64(0x96965231F4C49662),
	SPH_C64(0xF9F962EF3A9BF9C3), SPH_C64(0xC5C5A397F666C533),
	SPH_C64(0x2525104AB1352594), SPH_C64(0x5959ABB220F25979),
	SPH_C64(0x8484D015AE54842A), SPH_C64(0x7272C5E4A7B772D5),
	SPH_C64(0x3939EC72DDD539E4), SPH_C64(0x4C4C1698615A4C2D),
	SPH_C64(0x5E5E94BC3BCA5E65), SPH_C64(0x78789FF085E778FD),
	SPH_C64(0x3838E570D8DD38E0), SPH_C64(0x8C8C980586148C0A),
	SPH_C64(0xD1D117BFB2C6D163), SPH_C64(0xA5A5E4570B41A5AE),
	SPH_C64(0xE2E2A1D94D43E2AF), SPH_C64(0x61614EC2F82F6199),
	SPH_C64(0xB3B3427B45F1B3F6), SPH_C64(0x21213442A5152184),
	SPH_C64(0x9C9C0825D6949C4A), SPH_C64(0x1E1EEE3C66F01E78),
	SPH_C64(0x4343618652224311), SPH_C64(0xC7C7B193FC76C73B),
	SPH_C64(0xFCFC4FE52BB3FCD7), SPH_C64(0x0404240814200410),
	SPH_C64(0x5151E3A208B25159), SPH_C64(0x9999252FC7BC995E),
	SPH_C64(0x6D6D22DAC44F6DA9), SPH_C64(0x0D0D651A39680D34),
	SPH_C64(0xFAFA79E93583FACF), SPH_C64(0xDFDF69A384B6DF5B),
	SPH_C64(0x7E7EA9FC9BD77EE5), SPH_C64(0x24241948B43D2490),
	SPH_C64(0x3B3BFE76D7C53BEC), SPH_C64(0xABAB9A4B3D31AB96),
	SPH_C64(0xCECEF081D13ECE1F), SPH_C64(0x1111992255881144),
	SPH_C64(0x8F8F8303890C8F06), SPH_C64(0x4E4E049C6B4A4E25),
	SPH_C64(0xB7B7667351D1B7E6), SPH_C64(0xEBEBE0CB600BEB8B),
	SPH_C64(0x3C3CC178CCFD3CF0), SPH_C64(0x8181FD1FBF7C813E),
	SPH_C64(0x94944035FED4946A), SPH_C64(0xF7F71CF30CEBF7FB),
	SPH_C64(0xB9B9186F67A1B9DE), SPH_C64(0x13138B265F98134C),
	SPH_C64(0x2C2C51589C7D2CB0), SPH_C64(0xD3D305BBB8D6D36B),
	SPH_C64(0xE7E78CD35C6BE7BB), SPH_C64(0x6E6E39DCCB576EA5),
	SPH_C64(0xC4C4AA95F36EC437), SPH_C64(0x03031B060F18030C),
	SPH_C64(0x5656DCAC138A5645), SPH_C64(0x44445E88491A440D),
	SPH_C64(0x7F7FA0FE9EDF7FE1), SPH_C64(0xA9A9884F3721A99E),
	SPH_C64(0x2A2A6754824D2AA8), SPH_C64(0xBBBB0A6B6DB1BBD6),
	SPH_C64(0xC1C1879FE246C123), SPH_C64(0x5353F1A602A25351),
	SPH_C64(0xDCDC72A58BAEDC57), SPH_C64(0x0B0B531627580B2C),
	SPH_C64(0x9D9D0127D39C9D4E), SPH_C64(0x6C6C2BD8C1476CAD),
	SPH_C64(0x3131A462F59531C4), SPH_C64(0x7474F3E8B98774CD),
	SPH_C64(0xF6F615F109E3F6FF), SPH_C64(0x46464C8C430A4605),
	SPH_C64(0xACACA5452609AC8A), SPH_C64(0x8989B50F973C891E),
	SPH_C64(0x1414B42844A01450), SPH_C64(0xE1E1BADF425BE1A3),
	SPH_C64(0x1616A62C4EB01658), SPH_C64(0x3A3AF774D2CD3AE8),
	SPH_C64(0x696906D2D06F69B9), SPH_C64(0x090941122D480924),
	SPH_C64(0x7070D7E0ADA770DD), SPH_C64(0xB6B66F7154D9B6E2),
	SPH_C64(0xD0D01EBDB7CED067), SPH_C64(0xEDEDD6C77E3BED93),
	SPH_C64(0xCCCCE285DB2ECC17), SPH_C64(0x42426884572A4215),
	SPH_C64(0x98982C2DC2B4985A), SPH_C64(0xA4A4ED550E49A4AA),
	SPH_C64(0x28287550885D28A0), SPH_C64(0x5C5C86B831DA5C6D),
	SPH_C64(0xF8F86BED3F93F8C7), SPH_C64(0x8686C211A4448622)
};

__constant__ static const sph_u64 pT7[256] = {
	SPH_C64(0x18D83078C0186018), SPH_C64(0x232646AF05238C23),
	SPH_C64(0xC6B891F97EC63FC6), SPH_C64(0xE8FBCD6F13E887E8),
	SPH_C64(0x87CB13A14C872687), SPH_C64(0xB8116D62A9B8DAB8),
	SPH_C64(0x0109020508010401), SPH_C64(0x4F0D9E6E424F214F),
	SPH_C64(0x369B6CEEAD36D836), SPH_C64(0xA6FF510459A6A2A6),
	SPH_C64(0xD20CB9BDDED26FD2), SPH_C64(0xF50EF706FBF5F3F5),
	SPH_C64(0x7996F280EF79F979), SPH_C64(0x6F30DECE5F6FA16F),
	SPH_C64(0x916D3FEFFC917E91), SPH_C64(0x52F8A407AA525552),
	SPH_C64(0x6047C0FD27609D60), SPH_C64(0xBC35657689BCCABC),
	SPH_C64(0x9B372BCDAC9B569B), SPH_C64(0x8E8A018C048E028E),
	SPH_C64(0xA3D25B1571A3B6A3), SPH_C64(0x0C6C183C600C300C),
	SPH_C64(0x7B84F68AFF7BF17B), SPH_C64(0x35806AE1B535D435),
	SPH_C64(0x1DF53A69E81D741D), SPH_C64(0xE0B3DD4753E0A7E0),
	SPH_C64(0xD721B3ACF6D77BD7), SPH_C64(0xC29C99ED5EC22FC2),
	SPH_C64(0x2E435C966D2EB82E), SPH_C64(0x4B29967A624B314B),
	SPH_C64(0xFE5DE121A3FEDFFE), SPH_C64(0x57D5AE1682574157),
	SPH_C64(0x15BD2A41A8155415), SPH_C64(0x77E8EEB69F77C177),
	SPH_C64(0x37926EEBA537DC37), SPH_C64(0xE59ED7567BE5B3E5),
	SPH_C64(0x9F1323D98C9F469F), SPH_C64(0xF023FD17D3F0E7F0),
	SPH_C64(0x4A20947F6A4A354A), SPH_C64(0xDA44A9959EDA4FDA),
	SPH_C64(0x58A2B025FA587D58), SPH_C64(0xC9CF8FCA06C903C9),
	SPH_C64(0x297C528D5529A429), SPH_C64(0x0A5A1422500A280A),
	SPH_C64(0xB1507F4FE1B1FEB1), SPH_C64(0xA0C95D1A69A0BAA0),
	SPH_C64(0x6B14D6DA7F6BB16B), SPH_C64(0x85D917AB5C852E85),
	SPH_C64(0xBD3C677381BDCEBD), SPH_C64(0x5D8FBA34D25D695D),
	SPH_C64(0x1090205080104010), SPH_C64(0xF407F503F3F4F7F4),
	SPH_C64(0xCBDD8BC016CB0BCB), SPH_C64(0x3ED37CC6ED3EF83E),
	SPH_C64(0x052D0A1128051405), SPH_C64(0x6778CEE61F678167),
	SPH_C64(0xE497D55373E4B7E4), SPH_C64(0x27024EBB25279C27),
	SPH_C64(0x4173825832411941), SPH_C64(0x8BA70B9D2C8B168B),
	SPH_C64(0xA7F6530151A7A6A7), SPH_C64(0x7DB2FA94CF7DE97D),
	SPH_C64(0x954937FBDC956E95), SPH_C64(0xD856AD9F8ED847D8),
	SPH_C64(0xFB70EB308BFBCBFB), SPH_C64(0xEECDC17123EE9FEE),
	SPH_C64(0x7CBBF891C77CED7C), SPH_C64(0x6671CCE317668566),
	SPH_C64(0xDD7BA78EA6DD53DD), SPH_C64(0x17AF2E4BB8175C17),
	SPH_C64(0x47458E4602470147), SPH_C64(0x9E1A21DC849E429E),
	SPH_C64(0xCAD489C51ECA0FCA), SPH_C64(0x2D585A99752DB42D),
	SPH_C64(0xBF2E637991BFC6BF), SPH_C64(0x073F0E1B38071C07),
	SPH_C64(0xADAC472301AD8EAD), SPH_C64(0x5AB0B42FEA5A755A),
	SPH_C64(0x83EF1BB56C833683), SPH_C64(0x33B666FF8533CC33),
	SPH_C64(0x635CC6F23F639163), SPH_C64(0x0212040A10020802),
	SPH_C64(0xAA93493839AA92AA), SPH_C64(0x71DEE2A8AF71D971),
	SPH_C64(0xC8C68DCF0EC807C8), SPH_C64(0x19D1327DC8196419),
	SPH_C64(0x493B927072493949), SPH_C64(0xD95FAF9A86D943D9),
	SPH_C64(0xF231F91DC3F2EFF2), SPH_C64(0xE3A8DB484BE3ABE3),
	SPH_C64(0x5BB9B62AE25B715B), SPH_C64(0x88BC0D9234881A88),
	SPH_C64(0x9A3E29C8A49A529A), SPH_C64(0x260B4CBE2D269826),
	SPH_C64(0x32BF64FA8D32C832), SPH_C64(0xB0597D4AE9B0FAB0),
	SPH_C64(0xE9F2CF6A1BE983E9), SPH_C64(0x0F771E33780F3C0F),
	SPH_C64(0xD533B7A6E6D573D5), SPH_C64(0x80F41DBA74803A80),
	SPH_C64(0xBE27617C99BEC2BE), SPH_C64(0xCDEB87DE26CD13CD),
	SPH_C64(0x348968E4BD34D034), SPH_C64(0x483290757A483D48),
	SPH_C64(0xFF54E324ABFFDBFF), SPH_C64(0x7A8DF48FF77AF57A),
	SPH_C64(0x90643DEAF4907A90), SPH_C64(0x5F9DBE3EC25F615F),
	SPH_C64(0x203D40A01D208020), SPH_C64(0x680FD0D56768BD68),
	SPH_C64(0x1ACA3472D01A681A), SPH_C64(0xAEB7412C19AE82AE),
	SPH_C64(0xB47D755EC9B4EAB4), SPH_C64(0x54CEA8199A544D54),
	SPH_C64(0x937F3BE5EC937693), SPH_C64(0x222F44AA0D228822),
	SPH_C64(0x6463C8E907648D64), SPH_C64(0xF12AFF12DBF1E3F1),
	SPH_C64(0x73CCE6A2BF73D173), SPH_C64(0x1282245A90124812),
	SPH_C64(0x407A805D3A401D40), SPH_C64(0x0848102840082008),
	SPH_C64(0xC3959BE856C32BC3), SPH_C64(0xECDFC57B33EC97EC),
	SPH_C64(0xDB4DAB9096DB4BDB), SPH_C64(0xA1C05F1F61A1BEA1),
	SPH_C64(0x8D9107831C8D0E8D), SPH_C64(0x3DC87AC9F53DF43D),
	SPH_C64(0x975B33F1CC976697), SPH_C64(0x0000000000000000),
	SPH_C64(0xCFF983D436CF1BCF), SPH_C64(0x2B6E5687452BAC2B),
	SPH_C64(0x76E1ECB39776C576), SPH_C64(0x82E619B064823282),
	SPH_C64(0xD628B1A9FED67FD6), SPH_C64(0x1BC33677D81B6C1B),
	SPH_C64(0xB574775BC1B5EEB5), SPH_C64(0xAFBE432911AF86AF),
	SPH_C64(0x6A1DD4DF776AB56A), SPH_C64(0x50EAA00DBA505D50),
	SPH_C64(0x45578A4C12450945), SPH_C64(0xF338FB18CBF3EBF3),
	SPH_C64(0x30AD60F09D30C030), SPH_C64(0xEFC4C3742BEF9BEF),
	SPH_C64(0x3FDA7EC3E53FFC3F), SPH_C64(0x55C7AA1C92554955),
	SPH_C64(0xA2DB591079A2B2A2), SPH_C64(0xEAE9C96503EA8FEA),
	SPH_C64(0x656ACAEC0F658965), SPH_C64(0xBA036968B9BAD2BA),
	SPH_C64(0x2F4A5E93652FBC2F), SPH_C64(0xC08E9DE74EC027C0),
	SPH_C64(0xDE60A181BEDE5FDE), SPH_C64(0x1CFC386CE01C701C),
	SPH_C64(0xFD46E72EBBFDD3FD), SPH_C64(0x4D1F9A64524D294D),
	SPH_C64(0x927639E0E4927292), SPH_C64(0x75FAEABC8F75C975),
	SPH_C64(0x06360C1E30061806), SPH_C64(0x8AAE0998248A128A),
	SPH_C64(0xB24B7940F9B2F2B2), SPH_C64(0xE685D15963E6BFE6),
	SPH_C64(0x0E7E1C36700E380E), SPH_C64(0x1FE73E63F81F7C1F),
	SPH_C64(0x6255C4F737629562), SPH_C64(0xD43AB5A3EED477D4),
	SPH_C64(0xA8814D3229A89AA8), SPH_C64(0x965231F4C4966296),
	SPH_C64(0xF962EF3A9BF9C3F9), SPH_C64(0xC5A397F666C533C5),
	SPH_C64(0x25104AB135259425), SPH_C64(0x59ABB220F2597959),
	SPH_C64(0x84D015AE54842A84), SPH_C64(0x72C5E4A7B772D572),
	SPH_C64(0x39EC72DDD539E439), SPH_C64(0x4C1698615A4C2D4C),
	SPH_C64(0x5E94BC3BCA5E655E), SPH_C64(0x789FF085E778FD78),
	SPH_C64(0x38E570D8DD38E038), SPH_C64(0x8C980586148C0A8C),
	SPH_C64(0xD117BFB2C6D163D1), SPH_C64(0xA5E4570B41A5AEA5),
	SPH_C64(0xE2A1D94D43E2AFE2), SPH_C64(0x614EC2F82F619961),
	SPH_C64(0xB3427B45F1B3F6B3), SPH_C64(0x213442A515218421),
	SPH_C64(0x9C0825D6949C4A9C), SPH_C64(0x1EEE3C66F01E781E),
	SPH_C64(0x4361865222431143), SPH_C64(0xC7B193FC76C73BC7),
	SPH_C64(0xFC4FE52BB3FCD7FC), SPH_C64(0x0424081420041004),
	SPH_C64(0x51E3A208B2515951), SPH_C64(0x99252FC7BC995E99),
	SPH_C64(0x6D22DAC44F6DA96D), SPH_C64(0x0D651A39680D340D),
	SPH_C64(0xFA79E93583FACFFA), SPH_C64(0xDF69A384B6DF5BDF),
	SPH_C64(0x7EA9FC9BD77EE57E), SPH_C64(0x241948B43D249024),
	SPH_C64(0x3BFE76D7C53BEC3B), SPH_C64(0xAB9A4B3D31AB96AB),
	SPH_C64(0xCEF081D13ECE1FCE), SPH_C64(0x1199225588114411),
	SPH_C64(0x8F8303890C8F068F), SPH_C64(0x4E049C6B4A4E254E),
	SPH_C64(0xB7667351D1B7E6B7), SPH_C64(0xEBE0CB600BEB8BEB),
	SPH_C64(0x3CC178CCFD3CF03C), SPH_C64(0x81FD1FBF7C813E81),
	SPH_C64(0x944035FED4946A94), SPH_C64(0xF71CF30CEBF7FBF7),
	SPH_C64(0xB9186F67A1B9DEB9), SPH_C64(0x138B265F98134C13),
	SPH_C64(0x2C51589C7D2CB02C), SPH_C64(0xD305BBB8D6D36BD3),
	SPH_C64(0xE78CD35C6BE7BBE7), SPH_C64(0x6E39DCCB576EA56E),
	SPH_C64(0xC4AA95F36EC437C4), SPH_C64(0x031B060F18030C03),
	SPH_C64(0x56DCAC138A564556), SPH_C64(0x445E88491A440D44),
	SPH_C64(0x7FA0FE9EDF7FE17F), SPH_C64(0xA9884F3721A99EA9),
	SPH_C64(0x2A6754824D2AA82A), SPH_C64(0xBB0A6B6DB1BBD6BB),
	SPH_C64(0xC1879FE246C123C1), SPH_C64(0x53F1A602A2535153),
	SPH_C64(0xDC72A58BAEDC57DC), SPH_C64(0x0B531627580B2C0B),
	SPH_C64(0x9D0127D39C9D4E9D), SPH_C64(0x6C2BD8C1476CAD6C),
	SPH_C64(0x31A462F59531C431), SPH_C64(0x74F3E8B98774CD74),
	SPH_C64(0xF615F109E3F6FFF6), SPH_C64(0x464C8C430A460546),
	SPH_C64(0xACA5452609AC8AAC), SPH_C64(0x89B50F973C891E89),
	SPH_C64(0x14B42844A0145014), SPH_C64(0xE1BADF425BE1A3E1),
	SPH_C64(0x16A62C4EB0165816), SPH_C64(0x3AF774D2CD3AE83A),
	SPH_C64(0x6906D2D06F69B969), SPH_C64(0x0941122D48092409),
	SPH_C64(0x70D7E0ADA770DD70), SPH_C64(0xB66F7154D9B6E2B6),
	SPH_C64(0xD01EBDB7CED067D0), SPH_C64(0xEDD6C77E3BED93ED),
	SPH_C64(0xCCE285DB2ECC17CC), SPH_C64(0x426884572A421542),
	SPH_C64(0x982C2DC2B4985A98), SPH_C64(0xA4ED550E49A4AAA4),
	SPH_C64(0x287550885D28A028), SPH_C64(0x5C86B831DA5C6D5C),
	SPH_C64(0xF86BED3F93F8C7F8), SPH_C64(0x86C211A444862286)
};

/*
 * Round constants.
 */
 __constant__ static const sph_u64 pRC[10] = {
	SPH_C64(0x4F01B887E8C62318),
	SPH_C64(0x52916F79F5D2A636),
	SPH_C64(0x357B0CA38E9BBC60),
	SPH_C64(0x57FE4B2EC2D7E01D),
	SPH_C64(0xDA4AF09FE5377715),
	SPH_C64(0x856BA0B10A29C958),
	SPH_C64(0x67053ECBF4105DBD),
	SPH_C64(0xD8957DA78B4127E4),
	SPH_C64(0x9E4717DD667CEEFB),
	SPH_C64(0x33835AAD07BF2DCA)
};


#define R_ELT(table, in, i0, i1, i2, i3, i4, i5, i6, i7) \
        xor8(table ## 0[BYTE(in ## i0, 0U)] \
        , table ## 1[BYTE(in ## i1, 8U)] \
        , table ## 2[BYTE(in ## i2, 16U)] \
        , table ## 3[BYTE(in ## i3, 24U)] \
        , table ## 4[BYTE(in ## i4, 32U)] \
        , table ## 5[BYTE(in ## i5, 40U)] \
        , __ldg(&pT6[BYTE(in ## i6, 48U)]) \
        , __ldg(&pT7[BYTE(in ## i7, 56U)]))

#define R_ELT1(table, in, i0, i1, i2, i3, i4, i5, i6, i7) \
        xor8(table ## 0[BYTE(in ## i0, 0U)] \
        , table ## 1[BYTE(in ## i1, 8U)] \
        , __ldg(&pT2[BYTE(in ## i2, 16U)]) \
        , table ## 3[BYTE(in ## i3, 24U)] \
        , table ## 4[BYTE(in ## i4, 32U)] \
        , __ldg(&pT5[BYTE(in ## i5, 40U)]) \
        , __ldg(&pT6[BYTE(in ## i6, 48U)]) \
        , __ldg(&pT7[BYTE(in ## i7, 56U)]))

#define R_(table, in, out, c0, c1, c2, c3, c4, c5, c6, c7)   do { \
	out ## 0 = xor1(R_ELT1(table, in, 0, 7, 6, 5, 4, 3, 2, 1) , c0); \
	out ## 1 = xor1(R_ELT(table, in, 1, 0, 7, 6, 5, 4, 3, 2) , c1); \
	out ## 2 = xor1(R_ELT(table, in, 2, 1, 0, 7, 6, 5, 4, 3) , c2); \
	out ## 3 = xor1(R_ELT1(table, in, 3, 2, 1, 0, 7, 6, 5, 4) , c3); \
	out ## 4 = xor1(R_ELT1(table, in, 4, 3, 2, 1, 0, 7, 6, 5) , c4); \
	out ## 5 = xor1(R_ELT(table, in, 5, 4, 3, 2, 1, 0, 7, 6) , c5); \
	out ## 6 = xor1(R_ELT1(table, in, 6, 5, 4, 3, 2, 1, 0, 7) , c6); \
	out ## 7 = xor1(R_ELT1(table, in, 7, 6, 5, 4, 3, 2, 1, 0) , c7); \
} while (0)

#define R_KSCHED(table, in, out, c) \
	R_(table, in, out, c, 0, 0, 0, 0, 0, 0, 0)

#define R_WENC(table, in, key, out) \
	R_(table, in, out, key ## 0, key ## 1, key ## 2, \
		key ## 3, key ## 4, key ## 5, key ## 6, key ## 7)

#define TRANS(dst, src)   do { \
		dst ## 0 = src ## 0; \
		dst ## 1 = src ## 1; \
		dst ## 2 = src ## 2; \
		dst ## 3 = src ## 3; \
		dst ## 4 = src ## 4; \
		dst ## 5 = src ## 5; \
		dst ## 6 = src ## 6; \
		dst ## 7 = src ## 7; \
	} while (0)

#define TPB_W 256
__global__ __launch_bounds__(TPB_W,2)
void x15_whirlpool_gpu_hash_128(uint32_t threads, uint32_t *g_hash){

    const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);

	__shared__ sph_u64 LT0[256], LT1[256], LT2[256], LT3[256], LT4[256], LT5[256];//, LT6[256], LT7[256];

	if (thread < threads)
	{
		uint32_t *Hash = &g_hash[thread<<4];
		uint64_t hx[8];

		if(threadIdx.x < 256)
		{
			uint64_t temp = pT0[threadIdx.x];
			LT0[threadIdx.x] = temp;
			LT1[threadIdx.x] = ROTL64(temp,8);
			LT2[threadIdx.x] = ROTL64(temp,16);
			LT3[threadIdx.x] = ROTL64(temp,24);
			LT4[threadIdx.x] = SWAPDWORDS(temp);;
			LT5[threadIdx.x] = ROTR64(temp,24);
		}

		*(uint2x4*)&hx[ 0] = __ldg4((uint2x4*)&Hash[0]);
		*(uint2x4*)&hx[ 4] = __ldg4((uint2x4*)&Hash[8]);
	
		sph_u64 n0, n1, n2, n3, n4, n5, n6, n7;
		sph_u64 h0, h1, h2, h3, h4, h5, h6, h7;
		sph_u64 state[8];

		n0 = (hx[0]);
		n1 = (hx[1]);
		n2 = (hx[2]);
		n3 = (hx[3]);
		n4 = (hx[4]);
		n5 = (hx[5]);
		n6 = (hx[6]);
		n7 = (hx[7]);

		h0 = h1 = h2 = h3 = h4 = h5 = h6 = h7 = 0;

		n0 ^= h0;
		n1 ^= h1;
		n2 ^= h2;
		n3 ^= h3;
		n4 ^= h4;
		n5 ^= h5;
		n6 ^= h6;
		n7 ^= h7;

		__syncthreads();

		for (unsigned r = 0; r < 10; r ++)
		{
			sph_u64 tmp0, tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7;

			R_KSCHED(LT, h, tmp, pRC[r]);
			TRANS(h, tmp);
			R_WENC(LT, n, h, tmp);
			TRANS(n, tmp);
		}

		state[0] = n0 ^ (hx[0]);
		state[1] = n1 ^ (hx[1]);
		state[2] = n2 ^ (hx[2]);
		state[3] = n3 ^ (hx[3]);
		state[4] = n4 ^ (hx[4]);
		state[5] = n5 ^ (hx[5]);
		state[6] = n6 ^ (hx[6]);
		state[7] = n7 ^ (hx[7]);

		n0 = n1 = n2 = n3 = n4 = n5 = n6 = n7 = 0;

		h0 = state[0];
		h1 = state[1];
		h2 = state[2];
		h3 = state[3];
		h4 = state[4];
		h5 = state[5];
		h6 = state[6];
		h7 = state[7];

		n0 ^= h0;
		n1 ^= h1;
		n2 ^= h2;
		n3 ^= h3;
		n4 ^= h4;
		n5 ^= h5;
		n6 ^= h6;
		n7 ^= h7;

		//#pragma unroll 10
		for (unsigned r = 0; r < 10; r++)
		{
			sph_u64 tmp0, tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7;

			R_KSCHED(LT, h, tmp, pRC[r]);
			TRANS(h, tmp);
			R_WENC(LT, n, h, tmp);
			TRANS(n, tmp);
		}

		state[0] = n0 ^ state[0];
		state[1] = n1 ^ state[1];
		state[2] = n2 ^ state[2];
		state[3] = n3 ^ state[3];
		state[4] = n4 ^ state[4];
		state[5] = n5 ^ state[5];
		state[6] = n6 ^ state[6];
		state[7] = n7 ^ state[7];

		n0 = 0x80;
		n1 = n2 = n3 = n4 = n5 = n6 = 0;
		n7 = 0x4000000000000;

		h0 = state[0];
		h1 = state[1];
		h2 = state[2];
		h3 = state[3];
		h4 = state[4];
		h5 = state[5];
		h6 = state[6];
		h7 = state[7];

		n0 ^= h0;
		n1 ^= h1;
		n2 ^= h2;
		n3 ^= h3;
		n4 ^= h4;
		n5 ^= h5;
		n6 ^= h6;
		n7 ^= h7;

		//  #pragma unroll 10
		for (unsigned r = 0; r < 10; r ++)
		{
			sph_u64 tmp0, tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7;

			R_KSCHED(LT, h, tmp, pRC[r]);
			TRANS(h, tmp);
			R_WENC(LT, n, h, tmp);
			TRANS(n, tmp);
		}

		state[0] ^= n0 ^ 0x80;
		state[1] ^= n1;
		state[2] ^= n2;
		state[3] ^= n3;
		state[4] ^= n4;
		state[5] ^= n5;
		state[6] ^= n6;
		state[7] ^= n7 ^ 0x4000000000000;

		#pragma unroll 8
		for (unsigned i = 0; i < 8; i ++){
			hx[i] = state[i];
		}

		*(uint2x4*)&Hash[0] = *(uint2x4*)&hx[ 0];
		*(uint2x4*)&Hash[8] = *(uint2x4*)&hx[ 4];
	}
}

__host__
void x15_whirlpool_cpu_hash_128(int thr_id, uint32_t threads, uint32_t *d_hash)
{
	const uint32_t threadsperblock = TPB_W;

	dim3 grid((threads + threadsperblock-1)/threadsperblock);
	dim3 block(threadsperblock);

	x15_whirlpool_gpu_hash_128<<<grid, block>>>(threads, d_hash);
}
