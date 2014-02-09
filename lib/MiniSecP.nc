#if DEBUG
#include "printf.h"
#define PRINTF(...) printf(__VA_ARGS__)
#define PRINTFFLUSH(...) printfflush()
#elif SIM
#define PRINTF(...) dbg("DEBUG",__VA_ARGS__)
#define PRINTFFLUSH(...)
#else  
#define PRINTF(...)
#define PRINTFFLUSH(...)
#endif
module MiniSecP @safe() {
	provides interface MiniSec as Sec;
	uses {
	   // interface AMPacket;
        interface OCBMode as CipherMode;
	}
}
implementation {
	uint16_t lastCount;
	uint16_t counter;
	uint8_t blockSize = 8;
	uint8_t keySize = 10;
	uint8_t preCombBlocks = 5;
	uint8_t tagLength = 4;
	//CipherModeContext cc;
    //uint8_t key[] = {0x05,0x15,0x25,0x35,0x45,0x55,0x65,0x75,0x85,0x95};
	//uint8_t iv[] = {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00};
	uint8_t decryptedMsg[] = {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 
						      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 
						      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
						      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
						      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
						  	 };

	uint8_t plainMsg[] = {0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08, 
                          0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,
                          0x11,0x12,0x13,0x14,0x15,0x16,0x01,0x02,
                          0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,
                          0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12
                          };
	uint8_t cipherMsg[] = {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 
						   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 
						   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
						   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
						   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
						  };
	uint8_t tag[] = {0x00,0x00,0x00,0x00};
	uint8_t msg_d[] = {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 
					   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 
					   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
					   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
					   0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
					   };
	uint8_t cipher_rec[] = {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 };
	uint8_t tag_rec[] = {0x00, 0x00, 0x00, 0x00};
	uint8_t tag_length = 4;
    uint8_t max_times_inc_IV;
    uint8_t nbre_times_inc_IV = 0;
    uint8_t nbreLB;
    uint8_t num_fails;
    uint8_t num_fb_resync; 
    uint8_t waiting_for_resync;

    int IncIV(uint8_t *IV, uint8_t inc);
    error_t incrementIV(uint8_t *iv_block);

    void DecIV(uint8_t *IV, uint8_t dec);
    void decIV(uint8_t *IV);

    void test(CipherModeContext *cc, uint8_t *iv){
        uint8_t valid = 0;
        PRINTF("Size of msg %d\n", sizeof(plainMsg));
        //Sec.encrypt(plainMsg, 40, tag, 8, iv);
        PRINTF("Plaintext block 0: %x\n", plainMsg[0]);
        call CipherMode.encrypt(cc, plainMsg, cipherMsg, tag, 40, iv);
        PRINTF("Encrypted stuff block 0: %x\n", cipherMsg[0]);PRINTFFLUSH();
        call CipherMode.decrypt(cc, cipherMsg, tag, decryptedMsg, 
                                40, iv, &valid);
        PRINTF("Plaintext block 0: %x\n", decryptedMsg[0]);
        PRINTF("Valid MAC: %s\n", (valid?"yes":"no"));PRINTFFLUSH();
    }

	command error_t Sec.init(CipherModeContext *cc, uint8_t *key, uint8_t key_size, uint8_t *iv,
                            uint8_t num_precomp_blks) {    
		call CipherMode.init(cc, key_size, key, tag_length, num_precomp_blks); 
        memset(cc->iv, 0, BLOCK_SIZE);
		lastCount = 0;
		counter = 0;
		nbreLB = 1;
		nbre_times_inc_IV = 0;
		max_times_inc_IV= 1;
		num_fails = 0;
		num_fb_resync= 4;
		waiting_for_resync=0;
        test(cc, cc->iv);
		return SUCCESS;
	}

	command error_t Sec.encrypt(CipherModeContext *cc, uint8_t *data, uint8_t length, uint8_t *taggy, 
								 uint8_t tag_len) {
	    uint8_t len_to_send;
		PRINTF("IV = %d", cc->iv + 7);
		call CipherMode.encrypt(cc, data, cipherMsg, taggy, length, cc->iv);
		memcpy(data, cipherMsg, length);
		PRINTF("WTF: %d\n", cc->iv[7] & (0xff >> (8-nbreLB)));PRINTFFLUSH();
	  	len_to_send = length + tag_len + 1;
	  	if(!incrementIV(cc->iv))
	  		return FAIL;
	   	else 
	   	    return len_to_send;
  	}

    command error_t Sec.decrypt(CipherModeContext *cc, uint8_t *cipher_blocks,
                                uint8_t *plain_blocks, uint8_t cipher_len, 
                                uint8_t *taggy, uint8_t *valid) {

        call CipherMode.decrypt(cc, cipher_blocks, taggy, plain_blocks, 
                                cipher_len, cc->iv, valid);
    }


    error_t incrementIV(uint8_t *iv_block) {
        uint8_t i;
        for (i = 7; i >= 0; i--) {
            iv_block[i]++;
            if (iv_block[i]) return SUCCESS;
        }
        return FAIL;
    }

}
