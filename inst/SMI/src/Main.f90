!**********************************************************************************
!  SOIL MOISTURE DROUGHT INDEX
!  PURPOSE:  
!            Estimate the soil moisture index using daily values generated by mHM
!  AUTHOR:   
!            Luis E. Samaniego-Eguiguren, UFZ, 02-2011
!  ALGORITHM: 
!            1) Read netcdf files daily/montly
!            2) Estimate monthly values of mHM-SM(sum over all layers) for each grid cell
!               - write them into netCDF
!            3) Estimate the empirical density function for each grid cell
!               using a non-parametric approach,  e.g. kernel smoother whose
!               bandwith is estimated with an unbiased cross-validation criterium
!            4) Estimate the mHM-drought index
!                    q(s) = \int_a^s f(s)ds 
!                    where:
!                         s = total soil moisture in mm over all soil layers in mHM
!                         a = lower limit of soil moisture a a given grid 
!                       q(s)= quantile corresponding to s
!            5) Estimate the following indices
!               - start
!               - duration
!               - magnitud
!               - severity
!               - affected area
!            6) Save results in netCDF format
!      
!  UPDATES:
!          Created   Sa  15.02.2011          main structure
!                    Sa  20.02.2011          debuging
!                    Sa  25.05.2011          v3. scenarios
!                    Sa  02.04.2012          v4. read COSMO SM
!                    Sa  22.06.2012          v4. read WRF-NOAH SM
!                    Zi  07.11.2016          modularized version
!                    Sa  20.03.2017          daily SMI, SAD flag, restructuring SAD
!                    ST  24.07.2018          bug fix in optimize width
!**********************************************************************************
program SM_Drought_Index

  use mo_kind,               only : i4, sp, dp
  use mo_message,            only : message
  use InputOutput,           only : WriteNetCDF, &
                                    nDurations, durList, nClusters, &
                                    writeResultsCluster, WriteResultsBasins, &
                                    WriteSMI, WriteCDF
  use mo_read,               only : ReadDataMain
  use mo_smi,                only : optimize_width, calSMI, invSMI
  use mo_drought_evaluation, only : droughtIndicator, ClusterEvolution, ClusterStats, calSAD
  use mo_smi_constants,      only : nodata_sp
  use mo_global_variables,   only : period
  !$ use omp_lib, ONLY : OMP_GET_NUM_THREADS           ! OpenMP routines

  implicit none

  ! variables
  logical                                    :: do_cluster  ! flag indicating whether cluster should be calculated
  logical                                    :: do_sad      ! flag indicating whether SAD analysis should be done
  logical                                    :: ext_smi  ! flag indicating to read external data for clustering 
  logical                                    :: invert_SMI  ! flag for inverting SMI
  !                                                         ! calculated or read from file
  logical                                    :: read_opt_h  ! read kernel width from file
  logical                                    :: silverman_h ! flag indicating whether kernel width 
  !                                                         ! should be optimized
  logical                                    :: do_basin    ! do_basin flag
  logical,     dimension(:,:), allocatable   :: mask

  integer(i4)                                :: ii
  type(period)                               :: per_kde, per_eval, per_smi
  integer(i4)                                :: nCells     ! number of effective cells
  integer(i4)                                :: d

  integer(i4)                                :: nCalendarStepsYear  !  Number of calendar time steps per year (month=12, day=365)

  integer(i4)                                :: thCellClus ! treshold  for cluster formation in space ~ 640 km2
  integer(i4)                                :: nCellInter ! number cells for joining clusters in time ~ 6400 km2
  integer(i4)                                :: deltaArea  ! number of cells per area interval
  integer(i4), dimension(:,:), allocatable   :: Basin_Id   ! IDs for basinwise drought analysis
  integer(i4), dimension(:,:), allocatable   :: cellCoor   ! 

  real(sp)                                   :: SMI_thld   ! SMI threshold for clustering
  real(sp)                                   :: cellsize   ! cell edge lenght of input data
  real(sp),    dimension(:,:), allocatable   :: SM_kde     ! monthly fields packed for estimation
  real(sp),    dimension(:,:), allocatable   :: SM_eval    ! monthly fields packed for evaluation
  real(sp),    dimension(:,:), allocatable   :: SM_invert  ! inverted monthly fields packed 
  real(sp),    dimension(:,:), allocatable   :: SMI        ! soil moisture index at evaluation array
  real(sp),    dimension(:,:,:), allocatable :: dummy_d3_sp
  integer(i4), dimension(:,:,:), allocatable :: SMIc       ! Drought indicator 1 - is under drought
  !                                                        !                   0 - no drought
  real(dp),    dimension(:,:), allocatable   :: opt_h      ! optimized kernel width field
  real(dp),    dimension(:,:), allocatable   :: lats, lons ! latitude and longitude fields of input

  
  ! file handling 
  character(256)                             :: outpath    ! output path for results

  !$OMP PARALLEL
  !$ ii = OMP_GET_NUM_THREADS()
  !$OMP END PARALLEL
  !$ print *, 'Run with OpenMP with ', ii, ' threads.'
  call ReadDataMain( SMI, do_cluster, ext_smi, invert_smi, &
       read_opt_h, silverman_h, opt_h, lats, lons, do_basin, &
       mask, SM_kde, SM_eval, Basin_Id, &
       SMI_thld, outpath, cellsize, thCellClus, nCellInter, &
       do_sad, deltaArea, nCalendarStepsYear, per_kde, per_eval, per_smi )
  
  ! initialize some variables
  nCells = count( mask ) ! number of effective cells
  
  call message('FINISHED READING')

  ! optimize kernel width
  if ( (.NOT. read_opt_h) .AND. (.NOT. ext_smi)) then
     call optimize_width( opt_h, silverman_h, SM_kde, nCalendarStepsYear, per_kde)
     call message('optimizing kernel width...ok')
  end if

  ! calculate SMI values for SM_eval
  if (.NOT. ext_smi) then 
    allocate( SMI( size( SM_eval, 1 ), size( SM_eval, 2 ) ) )
    SMI(:,:) = nodata_sp
    call calSMI( opt_h, SM_kde, SM_eval, nCalendarStepsYear, SMI, per_kde, per_eval )
    call message('calculating SMI... ok')
  end if

  ! invert SMI according to given cdf
  if (invert_smi) then
     ! testing with calculated SMI -> SM_invert == SM_kde
     call invSMI(SM_kde, opt_h, SMI, nCalendarStepsYear, per_kde, per_smi, SM_invert)
     ! write results to file
     allocate(dummy_D3_sp(size(mask, 1), size(mask, 2), size(SM_invert, 2)))
     do ii = 1, size(SM_invert, 2)
       dummy_D3_sp(:, :, ii) = unpack(SM_invert(:, ii), mask, nodata_sp)
     end do
     call WriteNetcdf(outpath, 2, per_smi, lats, lons, SM_invert=dummy_D3_sp)
     deallocate(dummy_D3_sp)
  end if

  ! write output
  if (.NOT. ext_smi) then
    call WriteSMI( outpath, SMI, mask, per_eval, lats, lons )
    call message('write SMI...ok')
  end if

  if ((.not. read_opt_h) .and. (.not. ext_smi)) then
    call WriteCDF( outpath, SM_kde, opt_h, mask, per_kde, nCalendarStepsYear, lats, lons )
    call message('write cdf_info file...ok')
  end if
     
  ! calculate drought cluster
  if ( do_cluster ) then
     ! drought indicator 
     call droughtIndicator( SMI, mask, SMI_thld, cellCoor, SMIc )
     call WriteNetCDF(outpath, 3, per_smi, lats, lons, SMIc=SMIc)
     
     ! cluster indentification
     call ClusterEvolution( SMIc,  size( mask, 1), size( mask, 2 ), size(SMI, 2), &
         nCells, cellCoor, nCellInter, thCellClus)
     call WriteNetCDF(outpath, 4, per_smi, lats, lons)

     ! statistics  
     call ClusterStats(SMI, mask, size( mask, 1), size( mask, 2 ), size(SMI, 2), nCells, SMI_thld )

     ! write results
     if (nClusters > 0) call writeResultsCluster(SMIc, outpath, 1, &
         per_smi%y_start, per_smi%y_end, size(SMI, 2), nCells, deltaArea, cellsize)
     call message('Cluster evolution ...ok')
  end if

  ! SAD analysis
  if ( do_sad ) then
     do d = 1, nDurations
        call calSAD(SMI, mask, d, size( mask, 1), size( mask, 2 ), size(SMI, 2), nCells, deltaArea, cellsize)
        ! write SAD for a given duration + percentiles
        call writeResultsCluster(SMIc, outpath, 2, per_smi%y_start, per_smi%y_end, size(SMI, 2), &
            nCells, deltaArea, cellsize, durList(d))
        call WriteNetCDF(outpath, 5, per_kde, lats, lons, duration=durList(d))
     end do
  end if
  
  ! make basin averages
  if ( do_basin ) then
     ! write SMI average over major basins
     call message('calculate Basin Results ...')
     call WriteResultsBasins( outpath, SMI, mask, per_kde%y_start, per_kde%y_end, size( SM_kde, 2 ), Basin_Id )
  end if

  ! print statement for check_cases
  call message('SMI: finished!')
  !
end program SM_Drought_Index
