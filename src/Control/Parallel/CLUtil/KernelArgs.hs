{-# LANGUAGE ScopedTypeVariables, FlexibleInstances, OverlappingInstances #-}
-- |Synchronous OpenCL kernel execution with easy support for 'Vector'
-- inputs and outputs.
module Control.Parallel.CLUtil.KernelArgs (KernelArgs, runKernel) where
import Control.Applicative
import Control.Monad (void, when)
import Data.Either (partitionEithers)
import Data.Maybe (catMaybes)
import Data.Vector.Storable (Vector)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (Storable, sizeOf)
import Control.Parallel.CLUtil.KernelArgTypes
import Control.Parallel.CLUtil.State
import Control.Parallel.CLUtil.VectorBuffers
import Control.Parallel.OpenCL

data PostExec = ReadOutput (Int -> IO (CLMem,Int))
              | FreeInput (IO ())

postToEither :: PostExec -> Either (Int -> IO (CLMem,Int)) (IO ())
postToEither (ReadOutput r) = Left r
postToEither (FreeInput m) = Right m

partitionPost :: [PostExec] -> ([Int -> IO (CLMem, Int)], [IO ()])
partitionPost = partitionEithers . map postToEither

-- Create a new vector from a buffer. Requires a 'CLCommandQueue' and
-- a pair of a memory buffer pointer and the number of elements to
-- read.
mkRead :: Storable a => CLCommandQueue -> (CLMem, Int) -> IO (Vector a)
mkRead q (mem,num) = do v <- bufferToVector q mem num []
                        _ <- clReleaseMemObject mem
                        return v

-- | Variable arity class patterned on "Text.Printf".
class KernelArgs a where
  -- Setting an argument requires a state, a kernel, the position of
  -- the argument, the number of work items specified so far, and a
  -- list of actions that prepare argument buffers and return the
  -- cleanup action to take when the kernel is finished.
  setArg :: OpenCLState -> CLKernel -> CLuint -> Maybe NumWorkItems
         -> Maybe WorkGroup -> [IO (Maybe PostExec)] -> a

runPrep :: [IO (Maybe PostExec)] -> IO ([Int -> IO (CLMem, Int)], [IO ()])
runPrep = fmap (partitionPost . catMaybes) . sequence . reverse

enqKernelAndWait :: CLCommandQueue -> CLKernel -> NumWorkItems
                 -> Maybe WorkGroup -> IO ()
enqKernelAndWait q k n wg = 
  do exec <- clEnqueueNDRangeKernel q k (workItemsList n) 
               (maybe [] workGroupSizes wg) []
     _ <- clWaitForEvents [exec]
     void $ clReleaseEvent exec

-- Synchronous execution of a kernel with no automatic outputs. This
-- is useful for kernels that modify user-managed buffers.
instance KernelArgs (IO ()) where
  setArg s k _ (Just n) wg prep = do
    (o, cleanup) <- runPrep prep
    when (not (null o)) (error "Outputs aren't bound!")
    enqKernelAndWait (clQueue s) k n wg
    sequence_ cleanup

-- Execute a kernel where the calling context is expecting a single
-- 'Vector' return value.
instance forall a. Storable a => KernelArgs (IO (Vector a)) where
  setArg s k _ (Just n) wg prep = do
    let q = clQueue s
    (o, cleanup) <- runPrep prep
    r1 <- case o of
            [] -> error "One output bound, none specified"
            [f] -> do x <- f (sizeOf (undefined::a))
                      return $ mkRead q x
            _ -> error "More outputs specified than bound"
    enqKernelAndWait q k n wg
    sequence_ cleanup
    r1

-- Execute a kernel where the calling context is expecting two
-- 'Vector' return values.
instance forall a b. (Storable a, Storable b) => 
  KernelArgs (IO (Vector a, Vector b)) where
  setArg s k _ (Just n) wg prep = do
    let q = clQueue s
    (o, cleanup) <- runPrep prep
    (r1,r2) <- case o of
                 [] -> error "Two outputs bound, none specified"
                 [_] -> error "Two outputs bound, one specified"
                 [f,g] -> do x <- f (sizeOf (undefined::a))
                             y <- g (sizeOf (undefined::b))
                             return (mkRead q x, mkRead q y)
                 _ -> error "More outputs specified than bound"
    enqKernelAndWait q k n wg
    sequence_ cleanup
    (,) <$> r1 <*> r2

-- Execute a kernel where the calling context is expecting three
-- 'Vector' return values.
instance forall a b c. (Storable a, Storable b, Storable c) => 
  KernelArgs (IO (Vector a, Vector b, Vector c)) where
  setArg s k _ (Just n) wg prep = do
    let q = clQueue s
    (o, cleanup) <- runPrep prep
    (r1,r2,r3) <- case o of
                    [f,g,h] -> do x <- f (sizeOf (undefined::a))
                                  y <- g (sizeOf (undefined::b))
                                  z <- h (sizeOf (undefined::c))
                                  return (mkRead q x, mkRead q y, mkRead q z)
                    _ -> error "Different number of outputs specified than bound"
    enqKernelAndWait q k n wg
    sequence_ cleanup
    (,,) <$> r1 <*> r2 <*> r3

-- Pass an arbitrary 'Storable' as a kernel argument.
instance (Storable a, KernelArgs r) => KernelArgs (a -> r) where
  setArg s k arg n wg prep = \a -> 
    let load = clSetKernelArgSto k arg a >> return Nothing
    in setArg s k (arg+1) n wg (load : prep)

-- Handle 'Vector' input arguments.
instance (Storable a, KernelArgs r) => KernelArgs (Vector a -> r) where
  setArg s k arg n wg prep = \v -> 
    let load = do b <- vectorToBuffer (clContext s) v
                  clSetKernelArgSto k arg b
                  return . Just . FreeInput $ void (clReleaseMemObject b)
    in setArg s k (arg+1) n wg (load : prep)

-- Keep track of an argument that specifies the number of work items
-- to execute.
instance KernelArgs r => KernelArgs (NumWorkItems -> r) where
  setArg s k arg _ wg prep = \n -> setArg s k arg (Just n) wg prep

-- Keep track of an argument that specifies the local work group size.
instance KernelArgs r => KernelArgs (WorkGroup -> r) where
  setArg s k arg n _ prep = \wg -> setArg s k arg n (Just wg) prep

-- Handle 'Vector' outputs by automatically managing the underlying
-- OpenCL buffers.
instance KernelArgs r => KernelArgs (OutputSize -> r) where
  setArg s k arg n wg prep = 
    \(Out m) -> 
      let alloc sz = do b <- clCreateBuffer (clContext s) 
                                            [CL_MEM_WRITE_ONLY]
                                            (m*sz, nullPtr)
                        clSetKernelArgSto k arg b
                        return (b,m)
      in setArg s k (arg+1) n wg (return (Just $ ReadOutput alloc) : prep)

instance (KernelArgs r, Storable a) => KernelArgs (LocalMem a -> r) where
  setArg s k arg n wg prep = 
    \(Local m) -> let sz = m * sizeOf (undefined::a)
                      local = do clSetKernelArg k arg sz nullPtr
                                 return Nothing
                  in setArg s k (arg+1) n wg (local:prep)

-- |Simple interface for calling an OpenCL kernel. Supports input
-- 'Vector' and 'Storable' arguments, and produces 'Vector' outputs.
--
-- > vOut <- runKernel cluState kernel vInput (Work1D 10) (Out 10)
runKernel :: KernelArgs a => OpenCLState -> CLKernel -> a
runKernel s k = setArg s k 0 Nothing Nothing []
