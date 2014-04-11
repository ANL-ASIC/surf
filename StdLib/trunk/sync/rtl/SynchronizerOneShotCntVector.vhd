-------------------------------------------------------------------------------
-- Title      : 
-------------------------------------------------------------------------------
-- File       : SynchronizerOneShotCntVector.vhd
-- Author     : Larry Ruckman  <ruckman@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2014-04-11
-- Last update: 2014-04-11
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- Copyright (c) 2014 SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

use work.StdRtlPkg.all;

entity SynchronizerOneShotCntVector is
   generic (
      TPD_G           : time                  := 1 ns; -- Simulation FF output delay
      RST_POLARITY_G  : sl                    := '1';  -- '1' for active HIGH reset, '0' for active LOW reset
      RST_ASYNC_G     : boolean               := false;-- Reset is asynchronous
      RELEASE_DELAY_G : positive              := 3;    -- Delay between deassertion of async and sync resets
      IN_POLARITY_G   : slv                   := "1";  -- 0 for active LOW, 1 for active HIGH
      OUT_POLARITY_G  : slv                   := "1";  -- 0 for active LOW, 1 for active HIGH
      USE_DSP48_G     : string                := "yes";
      CNT_ROLLOVER_G  : boolean               := false;-- Set to true to allow the counter roll over
      CNT_WIDTH_G     : natural range 1 to 48 := 48;
      WIDTH_G         : integer               := 2);
   port (
      clk     : in  sl;                              -- Clock to be SYNC'd to
      rst     : in  sl := not RST_POLARITY_G;        -- Optional reset
      dataIn  : in  slv(WIDTH_G-1 downto 0);         -- Data to be 'synced'
      dataOut : out slv(WIDTH_G-1 downto 0);         -- Synced data
      cntOut  : out SlvArray(WIDTH_G-1 downto 0));   -- Synced counter
end SynchronizerOneShotCntVector;

architecture mapping of SynchronizerOneShotCntVector is

   type PolarityVectorArray is array (WIDTH_G-1 downto 0) of sl;

   function FillVectorArray (INPUT : slv)
      return PolarityVectorArray is
      variable retVar : PolarityVectorArray := (others => '1');
   begin
      if INPUT = "1" then
         retVar := (others => '1');
      else
         for i in WIDTH_G-1 downto 0 loop
            retVar(i) := INPUT(i);
         end loop;
      end if;
      return retVar;
   end function FillVectorArray;

   constant IN_POLARITY_C  : PolarityVectorArray := FillVectorArray(IN_POLARITY_G);
   constant OUT_POLARITY_C : PolarityVectorArray := FillVectorArray(OUT_POLARITY_G);

   type MySlvArray is array (WIDTH_G-1 downto 0) of slv(CNT_WIDTH_G-1 downto 0);

   signal cnt : MySlvArray;
   
begin

   GEN_VEC :
   for i in (WIDTH_G-1) downto 0 generate
      
      SyncOneShotCnt_Inst : entity work.SynchronizerOneShotCnt
         generic map (
            TPD_G           => TPD_G,
            RST_POLARITY_G  => RST_POLARITY_G,
            RST_ASYNC_G     => RST_ASYNC_G,
            RELEASE_DELAY_G => RELEASE_DELAY_G,
            IN_POLARITY_G   => IN_POLARITY_C(i),
            OUT_POLARITY_G  => OUT_POLARITY_C(i),
            USE_DSP48_G     => USE_DSP48_G,
            CNT_ROLLOVER_G  => CNT_ROLLOVER_G,
            CNT_WIDTH_G     => CNT_WIDTH_G)      
         port map (
            clk     => clk,
            rst     => rst,
            dataIn  => dataIn(i),
            dataOut => dataOut(i),
            cntOut  => cnt(i)); 

      cntOut(i) <= cnt(i);
      
   end generate GEN_VEC;
   
end architecture mapping;