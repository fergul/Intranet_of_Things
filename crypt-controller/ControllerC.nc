#include <string.h>
#include <stdlib.h>
#include "Timer.h"
#include "ChannelTable.h"
#include "ChannelState.h"
#include "KNoTProtocol.h"
#include "KNoT.h"
#include "ECC.h"
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

#define HOME_CHANNEL 0
#define isAsymActive() 1
#define VALID_PKC 1

module ControllerC @safe()
{
  uses {
    interface Boot;
    interface SplitControl as SerialControl;
    interface AMSend as SerialSend;
    interface Receive as SerialReceive;
    interface Timer<TMilli> as CleanerTimer;
    interface LEDBlink;
    interface ChannelTable;
    interface ChannelState;
    interface KNoTCrypt as KNoT;
  }
}
implementation
{
  bool serialSendBusy = FALSE;
	ChanState home_chan;
  uint32_t nonce;
	uint8_t testKey[] = {0x05,0x15,0x25,0x35,0x45,0x55,0x65,0x75,0x85,0x95};
	uint8_t testKey_size = 10;
  Point publicKey = { .x = {0x5d75, 0xa416, 0x94f6, 0x703e, 0x7f9e, 0xf511, 0x3315, 0x3b73, 0x7ca8, 0x442b},
                      .y = {0xbf3e, 0xeeef, 0x7517, 0x1505, 0x4f20, 0x9bae, 0x3426, 0x5b00, 0x377c, 0xac91}
                    };
  Point pkc_signature = { .x = {0x6df6, 0x675b, 0x44d9, 0x3e11, 0xd26c, 0xb723, 0x5b14, 0x3b7d, 0x8fc1, 0xcfcc},
                          .y = {0x9ffb, 0xcba4, 0xf71c, 0xfed3, 0xbdda, 0xcca6, 0x15f0, 0x4f2e, 0xe17f, 0x69ad}
                        };
  uint16_t privateKey[11] = {0xbf3d, 0x27bd, 0x26a3, 0xa2d7, 0x1225, 0x2cc1, 0x7899, 0xd02d, 0x914c, 0x1382, 0x0000};
  /* Checks the timer for a channel's state, retransmitting when necessary */
	void check_timer(ChanState *state) {
    decrement_ticks(state);
    if (ticks_left(state)) return;
    if (attempts_left(state)) {
    	if (in_waiting_state(state)) 
        call KNoT.send_on_chan(state, (PDataPayload *)&(state->packet));
      else 
        call KNoT.ping(state); /* PING A LING LONG */
      set_ticks(state, state->ticks * 2); /* Exponential (double) retransmission */
      decrement_attempts(state);
      PRINTF("CLN>> Attempts left %d\n", state->attempts_left);
      PRINTF("CLN>> Retrying packet...\n");
    } else {
      PRINTF("CLN>> CLOSING CHANNEL %d DUE TO TIMEOUT\n", state->chan_num);
      call KNoT.close_graceful(state);
      call ChannelTable.remove_channel(state->chan_num);
    }
	}

	/* Run once every 20ms */
	void cleaner(){
		ChanState *state;
		int i = 1;
    for (; i < CHANNEL_NUM; i++) {
    	state = call ChannelTable.get_channel_state(i);
      //if (state && state->state <= 11) check_timer(state);
    }
    /*if (home_channel_state.state != STATE_IDLE) {
            check_timer(&home_channel_state);
    }*/
	}


  ChanState *verify_pkc(PDataPayload *pdp, uint8_t src){
    /*Assume most certificates will be good */
    ChanState *state = call ChannelTable.new_channel(); 
    if (call KNoT.asym_pkc_handler(state, pdp) != VALID_PKC) {
      call ChannelTable.remove_channel(state->chan_num);
      return 0;
    }
    state->remote_addr = src;
    state->remote_chan_num = pdp->ch.src_chan_num;
    state->seqno = pdp->dp.hdr.seqno;
    return state;
  }

  ChanState *retrieve_state(int chan, ChanHeader *ch, PDataPayload *pdp, int src){
    ChanState *s = call ChannelTable.get_channel_state(chan);
    if (!s){ /* Attempt to kill connection if no state held */
      PRINTF("Channel %d doesn't exist\n", chan);
      s = &home_chan;
      s->remote_chan_num = ch->src_chan_num;
      s->remote_addr = src;
      s->seqno = pdp->dp.hdr.seqno;
      call KNoT.close_graceful(s);
      return NULL;
    } 
    else return s;
  }

  void send_on_serial(PDataPayload *pdp) {
    message_t serial_pkt;
    PDataPayload *pkt = (PDataPayload *) (call SerialSend.getPayload(&serial_pkt, sizeof(DataPayload)));
    memcpy(pkt, pdp, sizeof(PDataPayload));
    if (call SerialSend.send(0, &serial_pkt, sizeof(PDataPayload)) == SUCCESS){
      serialSendBusy = TRUE;
    } 
    else {
      PRINTF("Couldn't send serial pkt\n");
      call LEDBlink.report_problem();
      }
  }

  void forward_to_cache(ChanState *state, uint8_t *data, uint8_t len) {
    PDataPayload *new_dp = (PDataPayload *)&(state->packet); 
    SerialResponseMsg *srmsg = (SerialResponseMsg *) new_dp->dp.data;
    memcpy(&(srmsg->data), data, len);
    srmsg->src = state->remote_addr;
    pdp_complete(new_pdp, state->chan_num, state->remote_chan_num, 
               RESPONSE, sizeof(SerialResponseMsg));
    send_on_serial(new_dp);
  }
	/*------------------------------------------------- */
	
	event void Boot.booted() {
		PRINTF("\n****** BOOTED *******\n");
    PRINTFFLUSH();
    call LEDBlink.report_problem();
    call ChannelTable.init_table();
    call ChannelState.init_state(&home_chan, 0);
    call CleanerTimer.startPeriodic(TICK_RATE);
    call KNoT.init_asymmetric(privateKey, &publicKey, &pkc_signature);
    }
    
 	event void SerialControl.startDone(error_t error) {}

  event void SerialControl.stopDone(error_t error) {}
   
/*-----------Received packet event, main state event ------------------------------- */
  event message_t* KNoT.receive(uint8_t src, message_t* msg, void* payload, uint8_t len) {
    uint8_t valid = 0;
  	ChanState *state;
    uint8_t recvBuff[10];
  	uint8_t cmd;
  	Packet *p = (Packet *) payload;
    SSecPacket *sp = NULL;
    PDataPayload *pdp = NULL;
    ChanHeader *ch = NULL;

    call LEDBlink.report_received();
	  PRINTF("SEC>> Received %s packet\n", is_symmetric(p->flags)?"Symmetric":
    			 is_asymmetric(p->flags)?"Asymmetric":"Plain");
    
    /* SYMMETRIC RECEIVE AND DECRYPT */
  	if (is_symmetric(p->flags)) {
      sp = (SSecPacket *) p;
      PRINTF("SEC>> IV: %d\n", sp->flags & (0xff >> 2));PRINTFFLUSH();
      if (sp->ch.dst_chan_num) { /* Get state for channel */ 
        state = retrieve_state(sp->ch.dst_chan_num, &(sp->ch), pdp, src);
        if (!state) return msg;
      }
  		call KNoT.receiveDecrypt(state, sp, len, &valid);
      if (!valid) return msg; /* Return if decryption failed */
  		pdp = (PDataPayload *) (&sp->ch); /* Offsetting to start of pdp */
  	} 
    /* ASYMMETRIC RECIEVE, DECRYPT AND PROCESS */
    else if (is_asymmetric(p->flags)) { 
      if (!isAsymActive()) return msg; /* Don't waste time/energy */
      pdp = (PDataPayload *) &(p->ch);

      if (pdp->dp.hdr.cmd == ASYM_QUERY){
        PRINTF("Received query\n");PRINTFFLUSH();
        state = verify_pkc(pdp, src);
        if (!state) return msg;
        call KNoT.send_asym_resp(state);
        set_state(state, STATE_ASYM_RESP);
      }
      else if (pdp->dp.hdr.cmd == ASYM_RESPONSE){
        PRINTF("Received response %d\n", pdp->ch.dst_chan_num);PRINTFFLUSH();
        state = verify_pkc(pdp, src);
        if (!state) return msg;
        call KNoT.send_resp_ack(state);
        set_state(state, STATE_ASYM_RESP);
      }
      else if (pdp->dp.hdr.cmd == ASYM_RESP_ACK){
        PRINTF("Received response ack %d\n", pdp->ch.dst_chan_num);PRINTFFLUSH();
        state = call ChannelTable.get_channel_state(pdp->ch.dst_chan_num);
        if (!state) return msg;
        state->remote_chan_num = pdp->ch.src_chan_num;
        PRINTF("Generating Nonce and sending...\n");PRINTFFLUSH();
        nonce = call KNoT.asym_request_key(state);
        set_state(state, STATE_ASYM_REQ_KEY);
      }
      else if (pdp->dp.hdr.cmd == ASYM_KEY_REQ){
        PRINTF("Received key request %d\n", pdp->ch.dst_chan_num);PRINTFFLUSH();
        state = call ChannelTable.get_channel_state(pdp->ch.dst_chan_num);
        if (!state) return msg;
        nonce = call KNoT.asym_key_request_handler(state, pdp);
        call KNoT.asym_key_resp(state, nonce, testKey);
        call KNoT.init_symmetric(state, state->key, SYM_KEY_SIZE);
      }
      else if (pdp->dp.hdr.cmd == ASYM_KEY_RESP){
        PRINTF("Received key TX %d\n", len);
        state = call ChannelTable.get_channel_state(pdp->ch.dst_chan_num);
        if (call KNoT.asym_key_resp_handler(state, pdp, nonce)) {
          call KNoT.init_symmetric(state, state->key, SYM_KEY_SIZE);
          call KNoT.sym_handover(state);
        }
      }
      return msg;
    } 
    /* PLAIN PACKET */
    else {
      pdp = (PDataPayload *) &(p->ch);
      /* Grab state for requested channel */
      state = retrieve_state(sp->ch.dst_chan_num, &(pdp->ch), pdp, src);
      if (!state) return msg;
    }
    ch = &(pdp->ch);
  	cmd = pdp->dp.hdr.cmd;
  	PRINTF("CON>> Received packet from Thing: %d\n", src);
  	PRINTF("CON>> Received a %s command\n", cmdnames[cmd]);
  	PRINTF("CON>> Message for channel %d\n", ch->dst_chan_num);
  	PRINTFFLUSH();

  	switch(cmd) { /* Drop packets for cmds we don't accept */
      case(QUERY): PRINTF("NOT FOR US\n");PRINTFFLUSH(); return msg;
      case(CONNECT): return msg;
      case(QACK): call KNoT.qack_handler(&home_chan, pdp, src); return msg;
      case(DACK): return msg;
      case(SYM_HANDOVER): 
        call KNoT.sym_handover_handler(state, pdp);
        call KNoT.connect(state, state->remote_addr, 5);
        return msg;
  	}
    if (!call KNoT.valid_seqno(state, pdp)) {
  		PRINTF("Old packet\n");
  		return msg;
  	}
  	switch(cmd) {
  		case(CACK): call KNoT.controller_cack_handler(state, pdp); break;
  		case(RESPONSE): {
        call KNoT.response_handler(state, pdp, recvBuff); 
        forward_to_cache(state, recvBuff, 1);
        break;
      }
  		case(RSYN): {
        call KNoT.response_handler(state, pdp, recvBuff);
        forward_to_cache(state, recvBuff, 1);
        call KNoT.send_rack(state); 
        break;
      }
      // case(CMDACK):    command_ack_handler(state,pdp);break;
  		case(PING): call KNoT.ping_handler(state, pdp); break;
  		case(PACK): call KNoT.pack_handler(state, pdp); break;
  		case(DISCONNECT): {
        call KNoT.disconnect_handler(state, pdp); 
        call ChannelTable.remove_channel(state->chan_num); 
        break;
      }
  		default: PRINTF("Unknown CMD type\n");
  	}
    call LEDBlink.report_received();
    return msg; /* Return packet to TinyOS */
  }

	event message_t *SerialReceive.receive(message_t *msg, void* payload, uint8_t len){
  	PDataPayload *pdp = (PDataPayload *)payload;
    ChanState *s;
  	void * data = &(pdp->dp.data);
  	uint8_t cmd = pdp->dp.hdr.cmd;
  	call LEDBlink.report_received();
		
		PRINTF("SERIAL> Serial command received.\n");
		PRINTF("SERIAL> Packet length: %d\n", pdp->dp.dhdr.tlen);
		//PRINTF("SERIAL> Message for channel %d\n", ch->dst_chan_num);
		PRINTF("SERIAL> Command code: %d\n", pdp->dp.hdr.cmd);
		PRINTFFLUSH();

		switch (cmd) {
			case(QUERY): call KNoT.send_asym_query(&home_chan);break;
      //case(QUERY): call KNoT.query(&home_chan, 1/*((QueryMsg*)dp)->type*/);break;
			case(CONNECT): {
        s = call ChannelTable.get_channel_state(pdp->ch.src_chan_num);
        call KNoT.connect(s, s->remote_addr, ((SerialConnect*)data)->rate);
        break;
      }
		}
		call LEDBlink.report_received();
  	return msg;
    }

 	event void SerialSend.sendDone(message_t *msg, error_t error){
  	if (error == SUCCESS) call LEDBlink.report_sent();
    else call LEDBlink.report_problem();
    serialSendBusy = FALSE;
  }

   
  event void CleanerTimer.fired(){
  	cleaner();
  }

}