import Foundation

extension MIQFileKind {
    /// Short, upper-case format label for the Finder thumbnail's file-type badge
    /// (`QLThumbnailReply.extensionBadge`). Without it Finder badges a
    /// `.nii.gz`/`.mif.gz` thumbnail with the last path extension, "GZ", which
    /// says nothing about the volume inside, so compressed kinds share the label
    /// of their uncompressed format. MGZ keeps its own established name (also for
    /// the `.mgh.gz` spelling) because FreeSurfer users know the two apart.
    public var badgeLabel: String {
        switch self {
        case .nii, .niiGz: return "NII"
        case .mgh: return "MGH"
        case .mgz: return "MGZ"
        case .mif, .mifGz: return "MIF"
        case .nrrd: return "NRRD"
        case .nhdr: return "NHDR"
        case .mih: return "MIH"
        case .mha: return "MHA"
        case .mhd: return "MHD"
        case .zarr: return "ZARR"
        case .dicom: return "DCM"
        }
    }
}
