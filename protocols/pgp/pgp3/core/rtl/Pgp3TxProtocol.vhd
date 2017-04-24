-------------------------------------------------------------------------------
-- Title      : PGP3 Transmit Protocol
-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2017-03-30
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- Takes pre-packetized AxiStream frames and creates a PGP3 66/64 protocol
-- stream (pre-scrambler). Inserts IDLE and SKP codes as needed. Inserts
-- user K codes on request.
-------------------------------------------------------------------------------
-- This file is part of <PROJECT_NAME>. It is subject to
-- the license terms in the LICENSE.txt file found in the top-level directory
-- of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of <PROJECT_NAME>, including this file, may be
-- copied, modified, propagated, or distributed except according to the terms
-- contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;
use work.Pgp3Pkg.all;

entity Pgp3TxProtocol is

   generic (
      TPD_G            : time                  := 1 ns;
      NUM_VC_G         : integer range 1 to 16 := 4;
      STARTUP_HOLD_G   : integer               := 6000;
      SKP_INTERVAL_G   : integer               := 5000;
      SKP_BURST_SIZE_G : integer               := 8);

   port (
      -- User Transmit interface
      pgpTxClk    : in  sl;
      pgpTxRst    : in  sl;
      pgpTxIn     : in  Pgp3TxInType;
      pgpTxOut    : out Pgp3TxOutType;
      pgpTxMaster : in  AxiStreamMasterType;
      pgpTxSlave  : out AxiStreamSlaveType;

      -- Status of local receive fifos
      -- These get synchronized by the Pgp3Tx parent
      locRxFifoCtrl  : in AxiStreamCtrlArray(NUM_VC_G-1 downto 0);
      locRxLinkReady : in sl;
      remRxLinkReady : in sl;

      -- Output Interface
      protTxReady  : in  sl;
      protTxValid  : out sl;
      protTxStart  : out sl;
      protTxData   : out slv(63 downto 0);
      protTxHeader : out slv(1 downto 0));

end entity Pgp3TxProtocol;

architecture rtl of Pgp3TxProtocol is

   type RegType is record
      skpCount     : slv(15 downto 0);
      startupCount : integer;
      pgpTxSlave   : AxiStreamSlaveType;
      pgpTxOut     : Pgp3TxOutType;
      protTxValid  : sl;
      protTxStart  : sl;
      protTxData   : slv(63 downto 0);
      protTxHeader : slv(1 downto 0);
   end record RegType;

   constant REG_INIT_C : RegType := (
      skpCount     => (others => '0'),
      startupCount => 0,
      pgpTxSlave   => AXI_STREAM_SLAVE_INIT_C,
      pgpTxOut     => PGP3_TX_OUT_INIT_C,
      protTxValid  => '0',
      protTxStart  => '0',
      protTxData   => (others => '0'),
      protTxHeader => (others => '0'));

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

begin

   comb : process (locRxFifoCtrl, locRxLinkReady, pgpTxIn, pgpTxMaster, pgpTxRst, protTxReady, r) is
      variable v        : RegType;
      variable linkInfo : slv(39 downto 0);
   begin
      v := r;

      linkInfo := makeLinkInfo(locRxFifoCtrl, locRxLinkReady);

      -- Always increment skpCount
      v.skpCount := r.skpCount + 1;

      -- Don't accept new frame data by default
      v.pgpTxSlave.tReady := '0';

      v.pgpTxOut.frameTx    := '0';
      v.pgpTxOut.frameTxErr := '0';

      if (protTxReady = '1') then
         v.protTxValid := '0';
      end if;

      if (pgpTxMaster.tValid = '1' and v.protTxValid = '0') then
         v.protTxValid := '1';

         -- Send only IDLE and SKP for STARTUP_HOLD_G cycles after reset
         v.startupCount := r.startupCount + 1;
         if (r.startupCount = 0) then
            v.protTxStart := '1';
         end if;
         if (r.startupCount = STARTUP_HOLD_G) then
            v.startupCount       := r.startupCount;
            v.pgpTxOut.linkReady := '1';
         end if;

         -- Decide whether to send IDLE, SKP, USER or data frames.
         -- Coded in reverse order of priority

         -- Send idle chars by default
         v.protTxData(39 downto 0)  := linkInfo;
         v.protTxData(55 downto 40) := (others => '0');
         v.protTxData(63 downto 56) := IDLE_C;
         v.protTxHeader             := K_HEADER_C;

         -- Send data if there is data to send
         if (r.pgpTxOut.linkReady = '1') then
            v.pgpTxSlave.tReady := '1';  -- Accept the data

            if (ssiGetUserSof(PGP3_AXIS_CONFIG_C, pgpTxMaster) = '1') then
               -- SOF/SOC, format SOF/SOC char from data
               v.protTxData               := (others => '0');
               v.protTxData(63 downto 56) := ite(pgpTxMaster.tData(24) = '1', SOF_C, SOC_C);
               v.protTxData(39 downto 0)  := linkInfo;
               v.protTxData(43 downto 40) := pgpTxMaster.tData(11 downto 8);   -- Virtual Channel
               v.protTxData(55 downto 44) := pgpTxMaster.tData(43 downto 32);  -- Packet number
               v.protTxHeader             := K_HEADER_C;

            elsif (pgpTxMaster.tLast = '1') then
               -- EOF/EOC
               v.protTxData               := (others => '0');
               v.protTxData(63 downto 56) := ite(pgpTxMaster.tData(8) = '1', EOF_C, EOC_C);
               v.protTxData(7 downto 0)   := pgpTxMaster.tData(7 downto 0);    -- TUSER LAST
               v.protTxData(19 downto 16) := pgpTxMaster.tData(19 downto 16);  -- Last byte count
               v.protTxData(55 downto 24) := pgpTxMaster.tData(63 downto 32);  -- CRC
               v.protTxHeader             := K_HEADER_C;
               -- Debug output
               v.pgpTxOut.frameTx         := pgpTxMaster.tData(8);
               v.pgpTxOut.frameTxErr      := pgpTxMaster.tData(8) and pgpTxMaster.tData(0);
            else
               -- Normal data
               v.protTxData(63 downto 0) := pgpTxMaster.tData(63 downto 0);
               v.protTxHeader            := D_HEADER_C;
            end if;
         end if;

         -- 
         if (r.skpCount = SKP_INTERVAL_G-1) then
            v.skpCount                 := (others => '0');
            v.pgpTxSlave.tReady        := '0';  -- Override any data acceptance.
            v.protTxData               := (others => '0');
            v.protTxData(63 downto 56) := SKP_C;
            v.protTxHeader             := K_HEADER_C;
         end if;


         -- USER codes override data and delay SKP if they happen to coincide
         if (pgpTxIn.opCodeEn = '1' and r.pgpTxOut.linkReady = '1') then
            v.pgpTxSlave.tReady        := '0';  -- Override any data acceptance.
            v.protTxData(63 downto 56) := USER_C(conv_integer(pgpTxIn.opCodeNumber));
            v.protTxData(55 downto 0)  := pgpTxIn.opCodeData;
            -- If skip was interrupted, hold it for next cycle
            if (r.skpCount = SKP_INTERVAL_G-1) then
               v.skpCount := r.skpCount;
            end if;
         end if;

         if (pgpTxIn.disable = '1') then
            v.pgpTxOut.linkReady := '0';
            v.startupCount       := 0;
            v.protTxData         := (others => '0');
            v.protTxHeader       := (others => '0');
         end if;

      end if;

      if (pgpTxRst = '1') then
         v := REG_INIT_C;
      end if;

      rin <= v;

      pgpTxSlave   <= v.pgpTxSlave;
      protTxData   <= r.protTxData;
      protTxHeader <= r.protTxHeader;

   end process comb;

   seq : process (pgpTxClk) is
   begin
      if (rising_edge(pgpTxClk)) then
         r <= rin after TPD_G;
      end if;
   end process seq;
end architecture rtl;
