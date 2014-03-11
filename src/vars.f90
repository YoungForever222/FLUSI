! Variables for pseudospectral simnulations
module vars
  use mpi
  implicit none

  character*1,save:: tab ! Fortran lacks a native tab, so we set one up.

  ! Precision of doubles
  integer,parameter :: pr = 8 

  ! Method variables set in the program file:
  character(len=3),save:: method ! mhd  or fsi
  integer,save :: nf ! number of linear exponential fields (1 for HYD, 2 for MHD)
  integer,save :: nd ! number of fields (3 for NS, 6 for MHD)

  ! MPI and p3dfft variables and parameters
  integer,save :: mpisize, mpirank
  ! Local array bounds
  integer,dimension (1:3),save :: ra,rb,rs,ca,cb,cs

  ! p3dfft only parameters (move to appropraite .f90 file?)
  integer,save :: mpicommcart
  integer,dimension(2),save :: mpidims,mpicoords,mpicommslab
  
  ! Used in params.f90
  integer,parameter :: nlines=2048 ! maximum number of lines in PARAMS-file

  real(kind=pr),save :: pi ! 3.14....

  real(kind=pr),dimension(:),allocatable,save :: lin ! contains nu and eta

  ! Vabiables timing statistics.  Global to simplify syntax.
  real(kind=pr),save :: time_fft,time_ifft,time_vis,time_mask,time_fft2
  real(kind=pr),save :: time_vor,time_curl,time_p,time_nlk,time_u, time_ifft2
  real(kind=pr),save :: time_bckp,time_save,time_total,time_fluid,time_nlk_fft
  real(kind=pr),save :: time_sponge
  
  ! The mask array.  TODO: move out of shave_vars?
  real(kind=pr),dimension (:,:,:),allocatable,save :: mask ! mask function
  integer(kind=2),dimension (:,:,:),allocatable,save :: mask_color ! mask color function
  ! Velocity field inside the solid.  TODO: move out of shave_vars?
  real(kind=pr),allocatable,save :: us(:,:,:,:)  ! Velocity in solid


  ! Variables set via the parameters file
  real(kind=pr),save :: length 

  ! Domain size variables:
  integer,save :: nx,ny,nz
  real(kind=pr),save :: xl,yl,zl,dx,dy,dz,scalex,scaley,scalez

  ! FIXME: please document
  integer,save :: iDealias

  ! Parameters to set which files are saved and how often:
  integer,save :: iSaveVelocity,iSaveVorticity,iSavePress,iSaveMask
  integer,save :: iDoBackup
  integer,save :: iSaveXMF !directly write *.XMF files (1) or not (0)
  real(kind=pr),save :: tintegral ! Time between output of integral quantities
  real(kind=pr),save :: tsave ! Time between outpout of entire fields.
  ! compute drag force every itdrag time steps and compute unst corrections if
  ! you've told to do so.
  integer,save :: itdrag, unst_corrections
  

  ! Time-stepping parameters
  real(kind=pr),save :: tmax
  real(kind=pr),save :: cfl
  integer,save :: nt
  character(len=80),save :: iTimeMethodFluid

  ! Physical parameters:
  real(kind=pr),save :: nu

  ! Initial conditions:
  character(len=80),save :: inicond, file_ux,file_uy,file_uz
  character(len=80),save :: file_bx,file_by,file_bz
  real(kind=pr),save :: omega1 ! FIXME: what is omega1?


  ! Boundary conditions:
  character(len=80),save :: iMask
  integer,save :: iMoving,iPenalization
  real(kind=pr),save :: dt_fixed
  real(kind=pr),save :: eps
  real(kind=pr),save :: r1,r2,r3 ! Parameters for boundary conditions
  character(len=80) :: iSmoothing ! how to smooth the mask
  real(kind=pr),save :: pseudoeps, pseudodt, pseudoerrmin, pseudoerrmax

  ! Am I a fluid or a solid CPU?
  logical, save :: fluid_cpu, solid_cpu
  ! number of CPU, of CPU for fluid and CPU for solid
  integer, save :: ncpu, ncpu_fluid, ncpu_solid
  ! communicators:
  integer, save :: MPI_COMM_FLUID, MPI_COMM_SOLID
  
  contains 

    ! Routines to allocate real and complex arrays using the standard
    ! dimensions.
    subroutine allocreal(u)
      implicit none
      real(kind=pr),dimension(:,:,:),allocatable :: u
      allocate(u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3)))
    end subroutine allocreal
    
    subroutine alloccomplex(u)
      implicit none
      complex(kind=pr),dimension(:,:,:),allocatable :: u
      allocate(u(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3)))
    end subroutine alloccomplex
    
    subroutine allocrealnd(u)
      implicit none
      real(kind=pr),dimension(:,:,:,:),allocatable :: u
      allocate(u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd))
    end subroutine allocrealnd
    
    subroutine alloccomplexnd(u)
      implicit none
      complex(kind=pr),dimension(:,:,:,:),allocatable :: u
      allocate(u(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nd))
    end subroutine alloccomplexnd
end module vars


! Variables for fsi simulations
module fsi_vars
  use vars
  implicit none
  
  ! the sponge term is temporarily set in a global variable, but this will
  ! be changed in future versions
  complex(kind=pr), allocatable, save:: sponge(:,:,:,:)
  ! switch for vorticity sponge:
  character(len=80), save :: iVorticitySponge, iSpongeType
  real(kind=pr), save :: eps_sponge
  integer, save :: sponge_thickness
  
  ! Wings and body mask
  real (kind=pr),dimension (:,:,:,:),allocatable :: maskpart  
  
  ! cavity mask:
  character(len=80), save :: iCavity
  integer, save :: cavity_size, iChannel
  
  ! save forces and use unsteady corrections?
  integer, save :: compute_forces  
  
  ! for periodically repeating flows, it may be better to always have only 
  ! one set of files on the disk
  character(len=80) :: save_only_one_period
  

  real(kind=pr),save :: x0,y0,z0 ! Parameters for logical centre of obstacle
  real(kind=pr),save :: Uxmean,Uymean,Uzmean
  integer,save :: iMeanFlow
  integer,save :: iSaveSolidVelocity

  !-----------------------------------------------------------------------------
  ! The derived integral quantities for fluid-structure interactions.
  type Integrals
     real(kind=pr) :: time
     real(kind=pr) :: EKin
     real(kind=pr) :: Dissip
     real(kind=pr) :: Divergence
     real(kind=pr) :: Volume
     real(kind=pr),dimension(1:3) :: Force
     real(kind=pr),dimension(1:3) :: Force_unst
     real(kind=pr),dimension(1:3) :: Torque
     real(kind=pr),dimension(1:3) :: Torque_unst
  end type Integrals
  
  !-----------------------------------------------------------------------------
  ! derived datatype for insect parameters (for readability)
  type InsectParams ! documentaion see insect.f90
    character(len=80) :: WingShape, BodyType, HasHead, HasEye, BodyMotion
    character(len=80) :: FlappingMotion_right, FlappingMotion_left
    character(len=80) :: KineFromFile ! kinematics from file (Dmitry, 14 Nov 2013)
    ! parameters for body:
    real(kind=pr) :: L_body, b_body, R_head, R_eye
    ! parameters for wing shape:
    real(kind=pr) :: b_top, b_bot, L_chord, L_span, WingThickness
    ! this is a safety distance for smoothing:
    real(kind=pr) :: safety, smooth
    ! vectors desribing the positoions of jerry's key elements
    ! in the body coordinate system
    real(kind=pr), dimension(1:3) :: x_head, x_eye_r, x_eye_l, &
                                     x_pivot_l, x_pivot_r
    ! parameter for hovering:
    real(kind=pr) :: distance_from_sponge

    ! Wings and body forces
    type(Integrals), dimension(1:2) :: PartIntegrals
    ! Wings and body mask (-> MOVED TO BE GLOBAL; TO BE CHANGED LATER)
    !real (kind=pr),dimension (:,:,:,:),allocatable :: maskpart
  end type InsectParams
  

  ! derived datatype for rigid solid dynamics solver
  type SolidDynType
    ! solid dynamics solver flag (0=off, 1=on)
    integer :: idynamics
    ! vector of unknowns at new time step
    real(kind=pr), dimension(1:4) :: var_new
    ! vector of unknowns at current time step                                                                                                                
    real(kind=pr), dimension(1:4) :: var_this
    ! rhs at current time step                                                                                                                
    real(kind=pr), dimension(1:4) :: rhs_this
    ! rhs at previous time step                                                                                                                
    real(kind=pr), dimension(1:4) :: rhs_old
  end type SolidDynType
 

  type(Integrals),save :: GlobalIntegrals
  type(InsectParams), save :: Insect
  type(SolidDynType), save :: SolidDyn
 
  contains
  !-----------------------------------------------------------------------------
  
  ! this function simplifies my life with the insects
  real(kind=pr) function deg2rad(deg)
    use vars
    implicit none
    real(kind=pr), intent(in) :: deg
    deg2rad=deg*pi/180.d0
    return
  end function
end module fsi_vars



! Variables for mhd simulations
module mhd_vars
  use vars
  implicit none

  ! Physical parameters
  real(kind=pr),save :: eta ! magnetic diffusivity
  real(kind=pr),save :: b0, bc ! Boundary condition parameters
  real(kind=pr),save :: ay ! x*x + ay*y*y -r1*r1 == 0 ?in boundary conditions

  ! Determine whether we save various fields
  integer,save :: iSaveMagneticField,iSaveCurrent
end module mhd_vars


