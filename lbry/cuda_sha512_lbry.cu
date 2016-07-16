/**
 * sha-512 CUDA implementation.
 */

#include <stdio.h>
#include <stdint.h>
#include <memory.h>

//#define USE_ROT_ASM_OPT 0
#include <cuda_helper.h>

static __constant__ uint64_t K_512[80];

static const uint64_t K512[80] = {
	0x428A2F98D728AE22, 0x7137449123EF65CD, 0xB5C0FBCFEC4D3B2F, 0xE9B5DBA58189DBBC,
	0x3956C25BF348B538, 0x59F111F1B605D019, 0x923F82A4AF194F9B, 0xAB1C5ED5DA6D8118,
	0xD807AA98A3030242, 0x12835B0145706FBE, 0x243185BE4EE4B28C, 0x550C7DC3D5FFB4E2,
	0x72BE5D74F27B896F, 0x80DEB1FE3B1696B1, 0x9BDC06A725C71235, 0xC19BF174CF692694,
	0xE49B69C19EF14AD2, 0xEFBE4786384F25E3, 0x0FC19DC68B8CD5B5, 0x240CA1CC77AC9C65,
	0x2DE92C6F592B0275, 0x4A7484AA6EA6E483, 0x5CB0A9DCBD41FBD4, 0x76F988DA831153B5,
	0x983E5152EE66DFAB, 0xA831C66D2DB43210, 0xB00327C898FB213F, 0xBF597FC7BEEF0EE4,
	0xC6E00BF33DA88FC2, 0xD5A79147930AA725, 0x06CA6351E003826F, 0x142929670A0E6E70,
	0x27B70A8546D22FFC, 0x2E1B21385C26C926, 0x4D2C6DFC5AC42AED, 0x53380D139D95B3DF,
	0x650A73548BAF63DE, 0x766A0ABB3C77B2A8, 0x81C2C92E47EDAEE6, 0x92722C851482353B,
	0xA2BFE8A14CF10364, 0xA81A664BBC423001, 0xC24B8B70D0F89791, 0xC76C51A30654BE30,
	0xD192E819D6EF5218, 0xD69906245565A910, 0xF40E35855771202A, 0x106AA07032BBD1B8,
	0x19A4C116B8D2D0C8, 0x1E376C085141AB53, 0x2748774CDF8EEB99, 0x34B0BCB5E19B48A8,
	0x391C0CB3C5C95A63, 0x4ED8AA4AE3418ACB, 0x5B9CCA4F7763E373, 0x682E6FF3D6B2B8A3,
	0x748F82EE5DEFB2FC, 0x78A5636F43172F60, 0x84C87814A1F0AB72, 0x8CC702081A6439EC,
	0x90BEFFFA23631E28, 0xA4506CEBDE82BDE9, 0xBEF9A3F7B2C67915, 0xC67178F2E372532B,
	0xCA273ECEEA26619C, 0xD186B8C721C0C207, 0xEADA7DD6CDE0EB1E, 0xF57D4F7FEE6ED178,
	0x06F067AA72176FBA, 0x0A637DC5A2C898A6, 0x113F9804BEF90DAE, 0x1B710B35131C471B,
	0x28DB77F523047D84, 0x32CAAB7B40C72493, 0x3C9EBE0A15C9BEBC, 0x431D67C49C100D4C,
	0x4CC5D4BECB3E42B6, 0x597F299CFC657E2A, 0x5FCB6FAB3AD6FAEC, 0x6C44198C4A475817
};

//#undef xor3
//#define xor3(a,b,c) (a^b^c)

static __device__ __forceinline__
uint64_t bsg5_0(const uint64_t x)
{
	uint64_t r1 = ROTR64(x,28);
	uint64_t r2 = ROTR64(x,34);
	uint64_t r3 = ROTR64(x,39);
	return xor3(r1,r2,r3);
}

static __device__ __forceinline__
uint64_t bsg5_1(const uint64_t x)
{
	uint64_t r1 = ROTR64(x,14);
	uint64_t r2 = ROTR64(x,18);
	uint64_t r3 = ROTR64(x,41);
	return xor3(r1,r2,r3);
}

static __device__ __forceinline__
uint64_t ssg5_0(const uint64_t x)
{
	uint64_t r1 = ROTR64(x,1);
	uint64_t r2 = ROTR64(x,8);
	uint64_t r3 = shr_t64(x,7);
	return xor3(r1,r2,r3);
}

static __device__ __forceinline__
uint64_t ssg5_1(const uint64_t x)
{
	uint64_t r1 = ROTR64(x,19);
	uint64_t r2 = ROTR64(x,61);
	uint64_t r3 = shr_t64(x,6);
	return xor3(r1,r2,r3);
}

static __device__ __forceinline__
uint64_t xandx64(const uint64_t a, const uint64_t b, const uint64_t c)
{
	uint64_t result;
	asm("{  .reg .u64 m,n; // xandx64\n\t"
	    "xor.b64 m, %2,%3;\n\t"
	    "and.b64 n, m,%1;\n\t"
	    "xor.b64 %0, n,%3;\n\t"
	    "}" : "=l"(result) : "l"(a), "l"(b), "l"(c));
	return result;
}

static __device__ __forceinline__
void sha512_step2(uint64_t* r, uint64_t* W, uint64_t* K, const int ord, int i)
{
	int u = 8-ord;
	uint64_t a = r[(0+u) & 7];
	uint64_t b = r[(1+u) & 7];
	uint64_t c = r[(2+u) & 7];
	uint64_t d = r[(3+u) & 7];
	uint64_t e = r[(4+u) & 7];
	uint64_t f = r[(5+u) & 7];
	uint64_t g = r[(6+u) & 7];
	uint64_t h = r[(7+u) & 7];

	uint64_t T1 = h + bsg5_1(e) + xandx64(e,f,g) + W[i] + K[i];
	uint64_t T2 = bsg5_0(a) + andor(a,b,c);
	r[(3+u)& 7] = d + T1;
	r[(7+u)& 7] = T1 + T2;
}

/**************************************************************************************************/

__global__
void lbry_sha512_gpu_hash_32(const uint32_t threads, uint64_t *g_hash)
{
	const uint32_t thread = (blockDim.x * blockIdx.x + threadIdx.x);
	//if (thread < threads)
	{
		uint64_t *pHash = &g_hash[thread * 8U];

		uint64_t W[80];

		#pragma unroll
		for (int i = 0; i < 4; i++) {
			// 32 bytes input
			W[i] = pHash[i];
			//W[i] = cuda_swab64(pHash[i]); // made in sha256
		}

		W[4] = 0x8000000000000000; // end tag

		#pragma unroll
		for (int i = 5; i < 15; i++) W[i] = 0;

		W[15] = 0x100; // 256 bits

		//#pragma unroll
		//for (int i = 16; i < 78; i++) W[i] = 0;

		#pragma unroll
		for (int i = 16; i < 80; i++)
			W[i] = ssg5_1(W[i - 2]) + W[i - 7] + ssg5_0(W[i - 15]) + W[i - 16];

		const uint64_t IV512[8] = {
			0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
			0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179
		};

		uint64_t r[8];
		#pragma unroll
		for (int i = 0; i < 8; i++)
			r[i] = IV512[i];

		#pragma unroll 10
		for (int i = 0; i < 10; i++) {
			#pragma unroll 8
			for (int ord=0; ord<8; ord++)
				sha512_step2(r, W, K_512, ord, 8*i + ord);
		}

		#pragma unroll 8
		for (int i = 0; i < 8; i++)
			pHash[i] = cuda_swab64(r[i] + IV512[i]);
	}
}

__host__
void lbry_sha512_hash_32(int thr_id, uint32_t threads, uint32_t *d_hash, cudaStream_t stream)
{
	const int threadsperblock = 256;

	dim3 grid((threads + threadsperblock-1)/threadsperblock);
	dim3 block(threadsperblock);

	size_t shared_size = 0;
	lbry_sha512_gpu_hash_32 <<<grid, block, shared_size, stream>>> (threads, (uint64_t*)d_hash);
}

/**************************************************************************************************/

__host__
void lbry_sha512_init(int thr_id)
{
	cudaMemcpyToSymbol(K_512, K512, 80*sizeof(uint64_t), 0, cudaMemcpyHostToDevice);
}